/**
 * Module     : ICLMining.mo
 * Author     : ICLighthouse Team
 * License    : GNU General Public License v3.0
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/ICLMining
 */

import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Int "mo:base/Int";
import Float "mo:base/Float";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import Order "mo:base/Order";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Prelude "mo:base/Prelude";
import Error "mo:base/Error";
import Timer "mo:base/Timer";
import Cycles "mo:base/ExperimentalCycles";
import ICDexPair "mo:icl/ICDexTypes";
import ICDexMaker "mo:icl/ICDexMaker";
import ICDexRouter "mo:icl/ICDexRouter";
import DexAggregator "mo:icl/DexAggregator";
import DRC20 "mo:icl/DRC20";
import DRC205 "mo:icl/DRC205Types";
import ICRC1 "mo:icl/ICRC1";
import Hex "mo:icl/Hex";
import Tools "mo:icl/Tools";
import DRC207 "mo:icl/DRC207";

shared(installMsg) actor class ICLMining(rewardToken: Principal, rewardTokenFee: Nat) = this {
    type Timestamp = Nat; // second
    type PairCanister = Principal;
    type AccountId = Blob;
    type PairId = Principal;
    type PairInfo = {
        pairCanisterId: PairCanister;
        name: Text;
        token0: ICDexPair.TokenInfo; // (Principal, TokenSymbol, TokenStd);
        token1: ICDexPair.TokenInfo;
        token0Decimals: Nat;
        token1Decimals: Nat;
        score: Nat;
    };
    type OammId = Principal;
    type ShareDecimals = Nat;
    type AmountUsd = Nat;
    type RoundId = Nat; // base 1
    type RoundConfig = { 
        pairs: {#whitelist: [PairId]; #all};
        pairFilter: {minPairScore: Nat; blackList: [PairId]};
        content: Text;
        startTime: Timestamp; // 0 means from the end of the previous round
        endTime: Timestamp;
        supplyForTM: Nat;
        supplyForLM: Nat;
        preMiningDataFactorPercent: Nat; // 50 means 50%. When startTime > 0, the weight factor of the mining data between the endTime of the previous round and the startTime of this round.
    };
    type RoundData = { 
        config: RoundConfig;
        createdTime: Timestamp;
        status: {#Active; #Settling; #Closed}; // When the value is #Active, it is also necessary to combine startTime and endTime.
        points: {
            totalPointsForTM: Nat;
            totalPointsForLM: Nat;
            accountPointsForTM: Trie.Trie<AccountId, Nat>; // USD. Timed calculation of cumulative values, note timestamp `pointsUpdatedTime`.
            accountPointsForLM: Trie.Trie<AccountId, Nat>; // Time Weighted USD (TWUSD). Timed calculation of cumulative values, note timestamp `pointsUpdatedTime`.
            pointsUpdatedTime: Timestamp;
        };
        settlement: ?{
            tm: Trie.Trie<AccountId, Nat>;
            lm: Trie.Trie<AccountId, Nat>;
        };
    };
    type RoundDataReponse = { 
        config: RoundConfig;
        createdTime: Timestamp;
        status: {#Active; #Settling; #Closed};
        points: {
            totalPointsForTM: Nat;
            totalPointsForLM: Nat;
            accountPointsForTM: [(AccountId, Nat)]; // USD. The first 100.
            accountPointsForLM: [(AccountId, Nat)]; // Time Weighted USD (TWUSD). The first 100.
            pointsUpdatedTime: Timestamp;
        };
        settlement: ?{
            tm: [(AccountId, Nat)]; // ICL. The first 100.
            lm: [(AccountId, Nat)]; // ICL. The first 100.
        };
    };

    private let aggregator_: Principal = Principal.fromText("i2ied-uqaaa-aaaar-qaaza-cai");
    private let icdexRouter_: Principal = Principal.fromText("i5jcx-ziaaa-aaaar-qaazq-cai");
    private let dexData_: Principal = Principal.fromText("gwhbq-7aaaa-aaaar-qabya-cai");
    private let timerInterval: Timestamp = 1800; // seconds
    private stable var token_: Principal = rewardToken;
    private stable var tokenFee: Nat = rewardTokenFee;
    private stable var owner: Principal = installMsg.caller;
    private stable var dexPairs : Trie.Trie<PairId, PairInfo> = Trie.empty();
    private stable var dexOAMMs : [(PairId, OammId, ShareDecimals, ICDexMaker.UnitNetValue)] = [];
    private stable var tokenPrices : Trie.Trie<Principal, (priceUsd: Float, ts: Timestamp)> = Trie.empty();
    private stable var vipMakers: [(PairId, AccountId)] = [];
    private stable var nftHolders: [(AccountId, [ICDexRouter.NFT])] = [];
    private stable var roundCount: Nat = 0;
    private stable var timerId: Nat = 0;
    private stable var timerTs: Timestamp = 0;
    private stable var timerFirstTaskStarted: Bool = false; 
    private stable var miningRounds : Trie.Trie<RoundId, RoundData> = Trie.empty();
    private stable var isFetchingPoints : Bool = false;
    private stable var accountVols: Trie.Trie2D<PairId, AccountId, (ICDexPair.Vol, Timestamp)> = Trie.empty(); // After counting the points, save the original data here.
    private stable var accountTWShares: Trie.Trie2D<OammId, AccountId, (ICDexMaker.ShareWeighted, Timestamp)> = Trie.empty(); // After counting the points, save the original data here.
    private stable var accountBalances: Trie.Trie<AccountId, {available: Nat; locked: Nat}> = Trie.empty();

    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };

    private func _now() : Timestamp{ // second
        return Int.abs(Time.now() / 1000000000);
    };
    private func _onlyOwner(_caller: Principal) : Bool { 
        return Principal.isController(_caller) or _caller == owner;
    };
    private func _natToFloat(_n: Nat) : Float{
        let n: Int = _n;
        return Float.fromInt(n);
    };
    private func _floatToNat(_f: Float) : Nat{
        let i = Float.toInt(_f);
        assert(i >= 0);
        return Int.abs(i);
    };
    private func _toSaNat8(_sa: ?Blob) : ?[Nat8]{
        switch(_sa){
            case(?(sa)){ 
                if (sa.size() == 0){
                    return null;
                }else{
                    return ?Blob.toArray(sa); 
                };
            };
            case(_){ return null; };
        }
    };
    private func _accountIdToHex(_a: AccountId) : Text{
        return Hex.encode(Blob.toArray(_a));
    };
    private func _await() : async (){};

    private func _getBalance(_accountId: AccountId) : {available: Nat; locked: Nat}{
        switch(Trie.get(accountBalances, keyb(_accountId), Blob.equal)){
            case(?balance){
                return balance;
            };
            case(_){
                return {available = 0; locked = 0};
            };
        };
    };
    private func _setBalance(_accountId: AccountId, _available: Nat, _locked: Nat) : (){
        if (_available > 0 or _locked > 0){
            accountBalances := Trie.put(accountBalances, keyb(_accountId), Blob.equal, {available = _available; locked = _locked}).0;
        }else{
            accountBalances := Trie.remove(accountBalances, keyb(_accountId), Blob.equal).0;
        };
    };
    private func _addBalance(_accountId: AccountId, _value: Nat): (){
        let balance = _getBalance(_accountId);
        var available : Nat = balance.available + _value;
        var locked : Nat = balance.locked;
        _setBalance(_accountId, available, locked);
    };
    private func _subBalance(_accountId: AccountId, _value: Nat): (){
        let balance = _getBalance(_accountId);
        var available : Nat = balance.available;
        var locked : Nat = balance.locked;
        if (available >= _value){
            available := Nat.sub(available, _value);
        }else{
            Prelude.unreachable();
        };
        _setBalance(_accountId, available, locked);
    };
    private func _lockBalance(_accountId: AccountId, _value: Nat): (){
        let balance = _getBalance(_accountId);
        var available : Nat = balance.available;
        var locked : Nat = balance.locked + _value;
        if (available >= _value){
            available := Nat.sub(available, _value);
        }else{
            Prelude.unreachable();
        };
        _setBalance(_accountId, available, locked);
    };
    private func _unlockBalance(_accountId: AccountId, _value: Nat): (){
        let balance = _getBalance(_accountId);
        var available : Nat = balance.available + _value;
        var locked : Nat = balance.locked;
        if (locked >= _value){
            locked := Nat.sub(locked, _value);
        }else{
            Prelude.unreachable();
        };
        _setBalance(_accountId, available, locked);
    };
    private func _sublockedBalance(_accountId: AccountId, _value: Nat): (){
        let balance = _getBalance(_accountId);
        var available : Nat = balance.available;
        var locked : Nat = balance.locked;
        if (locked >= _value){
            locked := Nat.sub(locked, _value);
        }else{
            Prelude.unreachable();
        };
        _setBalance(_accountId, available, locked);
    };
    private func _transfer(_to: {owner: Principal; subaccount: ?Blob}, _value: Nat) : async* (){
        if (_value > tokenFee){
            let token: ICRC1.Self = actor(Principal.toText(token_));
            let args : ICRC1.TransferArgs = {
                memo = null;
                amount = Nat.sub(_value, tokenFee);
                fee = null;
                from_subaccount = null;
                to = _to;
                created_at_time = null;
            };
            let res = await token.icrc1_transfer(args);
            switch(res){
                case(#Ok(blockIndex)){};
                case(#Err(e)){ throw Error.reject("ICL transfer error."); };
            };
        }else{
            throw Error.reject("The amount is too small.");
        };
    };

    private func _getPairInfo(_pair: Principal): PairInfo{
        switch(Trie.get(dexPairs, keyp(_pair), Principal.equal)){
            case(?pairInfo){
                return pairInfo;
            };
            case(_){
                Prelude.unreachable();
            };
        };
    };
    private func _fetchPairs(): async* (){
        let aggr: DexAggregator.Self = actor(Principal.toText(aggregator_));
        var pairs: [(Principal, DexAggregator.TradingPair)] = [];
        let pageSize : Nat = 2000;
        var res = await aggr.getPairs(?"icdex", ?1, ?pageSize);
        pairs := res.data;
        if (res.totalPage > 1){
            for (page in Iter.range(2, res.totalPage)){
                let res = await aggr.getPairs(?"icdex", ?page, ?pageSize);
                pairs := Tools.arrayAppend(pairs, res.data);
            };
        };
        for ((pairId, pairInfo) in Trie.iter(dexPairs)){
            if (Option.isNull(Array.find(pairs, func (t: (Principal, DexAggregator.TradingPair)): Bool{
                pairId == t.0
            }))){
                dexPairs := Trie.remove(dexPairs, keyp(pairId), Principal.equal).0;
            };
        };
        pairs := Array.sort(pairs, func (t1: (Principal, DexAggregator.TradingPair), t2: (Principal, DexAggregator.TradingPair)): Order.Order{
            let scorePre : Nat = t1.1.score1 + t1.1.score2 + t1.1.score3;
            let scoreNext : Nat = t2.1.score1 + t2.1.score2 + t2.1.score3;
            return Nat.compare(scorePre, scoreNext); // ASC
        });
        label Loop for ((canisterId, pair) in pairs.vals()){
            let pairId = canisterId;
            var score : Nat = pair.score1 + pair.score2 + pair.score3;
            var token0Decimals: Nat = 0;
            var token1Decimals: Nat = 0;
            switch(Trie.get(dexPairs, keyp(pairId), Principal.equal)){
                case(?pairInfo){
                    token0Decimals := pairInfo.token0Decimals;
                    token1Decimals := pairInfo.token1Decimals;
                };
                case(_){
                    try{
                        token0Decimals := await* _fetchTokenDecimals(pair.pair.token0.0, pair.pair.token0.2);
                        token1Decimals := await* _fetchTokenDecimals(pair.pair.token1.0, pair.pair.token1.2);
                    }catch(e){
                        continue Loop;
                    };
                };
            };
            dexPairs := Trie.put(dexPairs, keyp(pairId), Principal.equal, {
                pairCanisterId = canisterId;
                name = pair.pair.dexName # ":" # pair.pair.token0.1 # "_" # pair.pair.token1.1;
                token0 = pair.pair.token0; // (Principal, TokenSymbol, TokenStd);
                token1 = pair.pair.token1;
                token0Decimals = token0Decimals;
                token1Decimals = token1Decimals;
                score = score;
            }: PairInfo).0;
        };
    };
    private func _fetchTokenDecimals(_token: Principal, _std: DRC205.TokenStd) : async* Nat{
        switch(_std){
            case(#drc20){
                let token: DRC20.Self = actor(Principal.toText(_token));
                return Nat8.toNat(await token.drc20_decimals());
            };
            case(_){
                let token: ICRC1.Self = actor(Principal.toText(_token));
                return Nat8.toNat(await token.icrc1_decimals());
            };
        };
    };
    private func _getTokenPrice(_token: Principal): Float{
        switch(Trie.get(tokenPrices, keyp(_token), Principal.equal)){
            case(?(v, ts)){
                return v;
            };
            case(_){ return 0.0 };
        };
    };
    private func _fetchTokenPrice(_token: Principal): async* Float{
        let dexData : actor{
            getPriceUsd : shared query (_token: Principal) -> async Float;
        } = actor(Principal.toText(dexData_));
        return await dexData.getPriceUsd(_token);
    };
    private func _fetchTokenPrices(): async* (){
        var tokens: [Principal] = [];
        for ((pairId, pairInfo) in Trie.iter(dexPairs)){
            if (Option.isNull(Array.find(tokens, func (t: Principal): Bool {t == pairInfo.token1.0}))){
                tokens := Tools.arrayAppend(tokens, [pairInfo.token1.0]);
            };
        };
        for (tokenCid in tokens.vals()){
            var toBeUpdated: Bool = false;
            switch(Trie.get(tokenPrices, keyp(tokenCid), Principal.equal)){
                case(?(v, ts)){
                    if (_now() > ts + 300){
                        toBeUpdated := true;
                    };
                };
                case(_){ toBeUpdated := true };
            };
            if (toBeUpdated){
                let price = await* _fetchTokenPrice(tokenCid);
                tokenPrices := Trie.put(tokenPrices, keyp(tokenCid), Principal.equal, (price, _now())).0;
            };
        };
    };
    private func _fetchPublicOAMMs() : async* (){
        let icdex: actor{
            maker_getPublicMakers : shared query (_pair: ?PairId, _page: ?Nat, _size: ?Nat) -> async Tools.TrieList<PairId, [(Principal, AccountId)]>;
        } = actor(Principal.toText(icdexRouter_));
        var oamms: [(PairId, Principal, Nat, ICDexMaker.UnitNetValue)] = [];
        let pageSize : Nat = 1000;
        var res = await icdex.maker_getPublicMakers(null, ?1, ?pageSize);
        for ((pairCid, items) in res.data.vals()){
            for ((makerCid, creator) in items.vals()){
                let pool: ICDexMaker.Self = actor(Principal.toText(makerCid));
                var nav = {ts = 0; token0 = 0; token1 = 0; price = 0; shares = 0};
                var decimals: Nat = 1;
                try{
                    nav := (await pool.stats()).latestUnitNetValue;
                    decimals := Nat8.toNat((await pool.info()).shareDecimals);
                }catch(e){};
                oamms := Tools.arrayAppend(oamms, [(pairCid, makerCid, decimals, nav)]);
            };
        };
        if (res.totalPage > 1){
            for (page in Iter.range(2, res.totalPage)){
                let res = await icdex.maker_getPublicMakers(null, ?page, ?pageSize);
                for ((pairCid, items) in res.data.vals()){
                    for ((makerCid, creator) in items.vals()){
                        let pool: ICDexMaker.Self = actor(Principal.toText(makerCid));
                        var nav = {ts = 0; token0 = 0; token1 = 0; price = 0; shares = 0};
                        var decimals: Nat = 1;
                        try{
                            nav := (await pool.stats()).latestUnitNetValue;
                            decimals := Nat8.toNat((await pool.info()).shareDecimals);
                        }catch(e){};
                        oamms := Tools.arrayAppend(oamms, [(pairCid, makerCid, decimals, nav)]);
                    };
                };
            };
        };
        dexOAMMs := oamms;
    };
    private func _isVipMaker(_pair: PairId, _accountId: AccountId): Bool {
        return Option.isSome(Array.find(vipMakers, func (t: (PairId, AccountId)): Bool{ _pair == t.0 and _accountId == t.1 }));
    };
    private func _fetchVipMakers() : async* (){
        let icdex: actor{
            getVipMakers : shared query (_pair: ?Principal) -> async [(PairId, AccountId)];
        } = actor(Principal.toText(icdexRouter_));
        vipMakers := await icdex.getVipMakers(null);
    };
    private func _nftAcceRate(_accountId: AccountId) : Float{ // 0,  0.15~0.25
        var aRate: Float = 0;
        switch(Array.find(nftHolders, func (t: (AccountId, [ICDexRouter.NFT])): Bool{ t.0 == _accountId })) {
            case(?(accountId, nfts)) {
                for ((user, nftId, balance, nftType, collectionId) in nfts.vals()){
                    if (balance > 0){
                        switch(nftType){
                            case(#MERCURY){ aRate := Float.max(aRate, 0.15) };
                            case(#VENUS){ aRate := Float.max(aRate, 0.17) };
                            case(#EARTH){ aRate := Float.max(aRate, 0.19) };
                            case(#MARS){ aRate := Float.max(aRate, 0.21) };
                            case(#JUPITER){ aRate := Float.max(aRate, 0.23) };
                            case(#SATURN){ aRate := Float.max(aRate, 0.25) };
                            case(#URANUS){ aRate := Float.max(aRate, 0.25) };
                            case(#NEPTUNE){ aRate := Float.max(aRate, 0.25) };
                            case(_){};
                        };
                    };
                };
            };
            case(_) {};
        };
        return aRate;
    };
    private func _fetchNftHolders() : async* (){
        let icdex: actor{
            NFTs : shared query () -> async [(AccountId, [ICDexRouter.NFT])];
        } = actor(Principal.toText(icdexRouter_));
        nftHolders := await icdex.NFTs();
        let aggr: actor{
            NFTs : shared query () -> async [(AccountId, [ICDexRouter.NFT])];
        } = actor(Principal.toText(aggregator_));
        nftHolders := Tools.arrayAppend(await aggr.NFTs(), nftHolders);
    };

    private func _getRound(_roundId: ?RoundId) : ?RoundData{
        return Trie.get(miningRounds, keyn(Option.get(_roundId, roundCount)), Nat.equal);
    };
    private func _newRound(_config: RoundConfig): RoundId{
        roundCount += 1;
        miningRounds := Trie.put(miningRounds, keyn(roundCount), Nat.equal, { 
            config = _config;
            createdTime = _now();
            status = #Active;
            points = {
                totalPointsForTM = 0;
                totalPointsForLM = 0;
                accountPointsForTM = Trie.empty();
                accountPointsForLM = Trie.empty();
                pointsUpdatedTime = _now();
            };
            settlement = null;
        }).0;
        return roundCount;
    };
    private func _updateRoundConfig(_roundId: RoundId, _args: {
        pairs: ?{#whitelist: [PairId]; #all};
        pairFilter: ?{minPairScore: Nat; blackList: [PairId]};
        content: ?Text;
        startTime: ?Timestamp; // 0 means from the end of the previous round
        endTime: ?Timestamp;
        supplyForTM: ?Nat;
        supplyForLM: ?Nat;
        preMiningDataFactorPercent: ?Nat;
    }) : (){
        // Update it with the rules:
        // * Time < startTime: all
        // * Time >= startTime and Time < endTime: content, endTime
        // * Time >= endTime: none
        // * timerFirstTaskStarted: not(startTime)
        let now = _now();
        switch(Trie.get(miningRounds, keyn(_roundId), Nat.equal)){
            case(?round){
                if (now >= round.config.startTime and now < round.config.endTime){
                    assert(Option.isNull(_args.pairs) and Option.isNull(_args.pairFilter) and Option.isNull(_args.startTime) and Option.isNull(_args.supplyForTM) and Option.isNull(_args.supplyForLM) and Option.isNull(_args.preMiningDataFactorPercent));
                };
                if (timerFirstTaskStarted){
                    assert(Option.isNull(_args.startTime));
                };
                if (now >= round.config.endTime){
                    assert(false);
                };
                miningRounds := Trie.put(miningRounds, keyn(_roundId), Nat.equal, { 
                    config = {
                        pairs = Option.get(_args.pairs, round.config.pairs);
                        pairFilter = Option.get(_args.pairFilter, round.config.pairFilter);
                        content = Option.get(_args.content, round.config.content);
                        startTime = Option.get(_args.startTime, round.config.startTime);
                        endTime = Option.get(_args.endTime, round.config.endTime);
                        supplyForTM = Option.get(_args.supplyForTM, round.config.supplyForTM);
                        supplyForLM = Option.get(_args.supplyForLM, round.config.supplyForLM);
                        preMiningDataFactorPercent = Option.get(_args.preMiningDataFactorPercent, round.config.preMiningDataFactorPercent);
                    };
                    createdTime = round.createdTime;
                    status = round.status;
                    points = round.points;
                    settlement = round.settlement;
                }).0;
            };
            case(_){
                Prelude.unreachable();
            };
        };
    };
    private func _updateRoundStatus(_roundId: RoundId, _status: {#Active; #Settling; #Closed}) : (){
        switch(Trie.get(miningRounds, keyn(_roundId), Nat.equal)){
            case(?round){
                miningRounds := Trie.put(miningRounds, keyn(_roundId), Nat.equal, { 
                    config = round.config;
                    createdTime = round.createdTime;
                    status = _status;
                    points = round.points;
                    settlement = round.settlement;
                }).0;
            };
            case(_){
                Prelude.unreachable();
            };
        };
    };
    private func _updateRoundPoints(_roundId: RoundId, _points: {
        addPointsForTM: [(AccountId, Nat)];
        addPointsForLM: [(AccountId, Nat)];
    }) : (){ // If status = #Settling / #Closed, it is not allowed to be modified.
        switch(Trie.get(miningRounds, keyn(_roundId), Nat.equal)){
            case(?round){
                assert(round.status != #Settling and round.status != #Closed);
                var totalPointsForTM = round.points.totalPointsForTM;
                var totalPointsForLM = round.points.totalPointsForLM;
                var accountPointsForTM = round.points.accountPointsForTM;
                var accountPointsForLM = round.points.accountPointsForLM;
                for ((accountId, addPoints) in _points.addPointsForTM.vals()){
                    totalPointsForTM += addPoints;
                    switch(Trie.get(accountPointsForTM, keyb(accountId), Blob.equal)){
                        case(?v){
                            accountPointsForTM := Trie.put(accountPointsForTM, keyb(accountId), Blob.equal, v + addPoints).0;
                        };
                        case(_){
                            accountPointsForTM := Trie.put(accountPointsForTM, keyb(accountId), Blob.equal, addPoints).0;
                        };
                    };
                };
                for ((accountId, addPoints) in _points.addPointsForLM.vals()){
                    totalPointsForLM += addPoints;
                    switch(Trie.get(accountPointsForLM, keyb(accountId), Blob.equal)){
                        case(?v){
                            accountPointsForLM := Trie.put(accountPointsForLM, keyb(accountId), Blob.equal, v + addPoints).0;
                        };
                        case(_){
                            accountPointsForLM := Trie.put(accountPointsForLM, keyb(accountId), Blob.equal, addPoints).0;
                        };
                    };
                };
                miningRounds := Trie.put(miningRounds, keyn(_roundId), Nat.equal, { 
                    config = round.config;
                    createdTime = round.createdTime;
                    status = round.status;
                    points = {
                        totalPointsForTM = totalPointsForTM;
                        totalPointsForLM = totalPointsForLM;
                        accountPointsForTM = accountPointsForTM;
                        accountPointsForLM = accountPointsForLM;
                        pointsUpdatedTime = _now();
                    };
                    settlement = round.settlement;
                }).0;
            };
            case(_){
                Prelude.unreachable();
            };
        };
    };
    private func _roundSettle(_roundId: RoundId): (){
        switch(Trie.get(miningRounds, keyn(_roundId), Nat.equal)){
            case(?round){
                assert(round.status == #Settling);
                let supplyForTM = round.config.supplyForTM; // ICL
                let supplyForLM = round.config.supplyForLM; // ICL
                var tmValues: Trie.Trie<AccountId, Nat> = Trie.empty(); // ICL
                var lmValues: Trie.Trie<AccountId, Nat> = Trie.empty(); // ICL
                for ((accountId, points) in Trie.iter(round.points.accountPointsForTM)){
                    let value = supplyForTM * points / round.points.totalPointsForTM;
                    _addBalance(accountId, value);
                    tmValues := Trie.put(tmValues, keyb(accountId), Blob.equal, value).0;
                };
                for ((accountId, points) in Trie.iter(round.points.accountPointsForLM)){
                    let value = supplyForLM * points / round.points.totalPointsForLM;
                    _addBalance(accountId, value);
                    lmValues := Trie.put(lmValues, keyb(accountId), Blob.equal, value).0;
                };
                miningRounds := Trie.put(miningRounds, keyn(_roundId), Nat.equal, { 
                    config = round.config;
                    createdTime = round.createdTime;
                    status = #Closed; // _updateRoundStatus(_roundId, #Closed);
                    points = round.points;
                    settlement = ?{ tm = tmValues; lm = lmValues };
                }).0;
            };
            case(_){
                Prelude.unreachable();
            };
        };
    };

    private func _getRoundPairs(_roundId: RoundId) : [PairInfo]{
        var res : [PairInfo] = [];
        switch(_getRound(?_roundId)){
            case(?round){
                let minPairScore = round.config.pairFilter.minPairScore;
                let blackList = round.config.pairFilter.blackList;
                switch(round.config.pairs){
                    case(#all){
                        for ((pairId, pairInfo) in Trie.iter(dexPairs)){
                            if (pairInfo.score >= minPairScore and Option.isNull(Array.find(blackList, func (t: PairId): Bool{t == pairId}))){
                                res := Tools.arrayAppend(res, [pairInfo]);
                            };
                        };
                    };
                    case(#whitelist(whitelist)){
                        for ((pairId, pairInfo) in Trie.iter(dexPairs)){
                            if (Option.isSome(Array.find(whitelist, func (t: PairId): Bool{t == pairId})) and 
                                pairInfo.score >= minPairScore and Option.isNull(Array.find(blackList, func (t: PairId): Bool{t == pairId}))){
                                res := Tools.arrayAppend(res, [pairInfo]);
                            };
                        };
                    };
                };
            };
            case(_){};
        };
        return res;
    };
    private func _getRoundOAMMs(_roundId: RoundId) : [(PairId, Principal, Nat, ICDexMaker.UnitNetValue)]{
        var res : [(PairId, Principal, Nat, ICDexMaker.UnitNetValue)] = dexOAMMs;
        let pairs = _getRoundPairs(_roundId);
        res := Array.filter(res, func (t: (PairId, Principal, Nat, ICDexMaker.UnitNetValue)): Bool{
            Option.isSome(Array.find(pairs, func (p: PairInfo): Bool{ p.pairCanisterId == t.0 }));
        });
        return res;
    };
    private func _getVol(_pairId: PairId, _accountId: AccountId) : ICDexPair.Vol{
        switch(Trie.get(accountVols, keyp(_pairId), Principal.equal)){
            case(?vols){
                switch(Trie.get(vols, keyb(_accountId), Blob.equal)){
                    case(?(vol, ts)){
                        return vol;
                    };
                    case(_){
                        return {value0 = 0; value1 = 0};
                    };
                };
            };
            case(_){
                return {value0 = 0; value1 = 0};
            };
        };
    };
    private func _setVol(_pairId: PairId, _accountId: AccountId, _vol: ICDexPair.Vol) : (){
        accountVols := Trie.put2D(accountVols, keyp(_pairId), Principal.equal, keyb(_accountId), Blob.equal, (_vol, _now()));
    };
    private func _fetchVols(_pairId: PairId) : async* [(AccountId, ICDexPair.Vol)]{
        let pair: actor{
            volsAll: shared query (_page: ?Tools.ListPage, _size: ?Tools.ListSize) -> async Tools.TrieList<AccountId, ICDexPair.Vol>;
        } = actor(Principal.toText(_pairId));
        try{
            var newVols: [(AccountId, ICDexPair.Vol)] = [];
            let pageSize : Nat = 2000;
            var res = await pair.volsAll(?1, ?pageSize);
            newVols := res.data;
            if (res.totalPage > 1){
                for (page in Iter.range(2, res.totalPage)){
                    let res = await pair.volsAll(?page, ?pageSize);
                    newVols := Tools.arrayAppend(newVols, res.data);
                };
            };
            return newVols;
        }catch(e){
            return [];
        };
    };
    private func _getTWShare(_oammId: OammId, _accountId: AccountId) : ICDexMaker.ShareWeighted{
        switch(Trie.get(accountTWShares, keyp(_oammId), Principal.equal)){
            case(?TWSs){
                switch(Trie.get(TWSs, keyb(_accountId), Blob.equal)){
                    case(?(tws, ts)){
                        return tws;
                    };
                    case(_){
                        return { shareTimeWeighted = 0; updateTime = 0 };
                    };
                };
            };
            case(_){
                return { shareTimeWeighted = 0; updateTime = 0 };
            };
        };
    };
    private func _setTWShare(_oammId: OammId, _accountId: AccountId, _share: ICDexMaker.ShareWeighted) : (){
        accountTWShares := Trie.put2D(accountTWShares, keyp(_oammId), Principal.equal, keyb(_accountId), Blob.equal, (_share, _now()));
    };
    private func _fetchLiquidity(_oammId: OammId) : async* [(AccountId, ICDexMaker.ShareWeighted)]{
        let pair: actor{
            accountSharesAll(_page: ?Tools.ListPage, _size: ?Tools.ListSize): async Tools.TrieList<AccountId, (Nat, ICDexMaker.ShareWeighted)>
        } = actor(Principal.toText(_oammId));
        try{
            var newTWSs: [(AccountId, (Nat, ICDexMaker.ShareWeighted))] = [];
            let pageSize : Nat = 2000;
            var res = await pair.accountSharesAll(?1, ?pageSize);
            newTWSs := res.data;
            if (res.totalPage > 1){
                for (page in Iter.range(2, res.totalPage)){
                    let res = await pair.accountSharesAll(?page, ?pageSize);
                    newTWSs := Tools.arrayAppend(newTWSs, res.data);
                };
            };
            return Array.map<(AccountId, (Nat, ICDexMaker.ShareWeighted)), (AccountId, ICDexMaker.ShareWeighted)>(newTWSs, 
                func (t: (AccountId, (Nat, ICDexMaker.ShareWeighted))): (AccountId, ICDexMaker.ShareWeighted){
                    (t.0, t.1.1)
                });
        }catch(e){
            return [];
        };
    };
    private func _fetchPoints() : async (){
        if (isFetchingPoints){
            timerTs := _now() + 30;
            timerId := Timer.setTimer(#seconds(30), _fetchPoints);
            return ();
        };
        isFetchingPoints := true;
        try{
            let roundId = roundCount;
            switch(_getRound(?roundId)){
                case(?round){
                    if (round.status == #Active){
                        let now = _now();
                        var preMiningDataFactorPercent: Nat = 100;
                        var status = round.status;
                        var addPointsForTM: [(AccountId, Nat)] = [];
                        var addPointsForLM: [(AccountId, Nat)] = [];
                        if (round.config.startTime > 0 and not(timerFirstTaskStarted)){
                            preMiningDataFactorPercent := round.config.preMiningDataFactorPercent;
                        };
                        timerFirstTaskStarted := true;
                        if (now >= round.config.endTime){
                            status := #Settling;
                            timerTs := 0;
                        }else{
                            timerTs := Nat.min(Nat.max(timerTs + timerInterval, now + 5), round.config.endTime);
                            timerId := Timer.setTimer(#seconds(Nat.sub(timerTs, now)), _fetchPoints);
                        };
                        await* _fetchTokenPrices();
                        await* _fetchVipMakers();
                        await* _fetchNftHolders();
                        let pairs = _getRoundPairs(roundId);
                        for (pairInfo in pairs.vals()){
                            let pairId = pairInfo.pairCanisterId;
                            let newVols = await* _fetchVols(pairId);
                            for ((accountId, vol) in newVols.vals()){
                                var factorVipMaker: Float = 1.0;
                                if (_isVipMaker(pairId, accountId)){
                                    factorVipMaker := 0.15;
                                };
                                let preVol: {value0: Nat; value1: Nat} = _getVol(pairId, accountId);
                                let nftAcceRate: Float = _nftAcceRate(accountId);
                                let token1PriceUsd: Float = _getTokenPrice(pairInfo.token1.0);
                                // point = (newVol.token1 - preVol.token1) / 10**token1.decimals * preMiningDataFactorPercent / 100 * factorVipMaker * (1 + nftAcceRate) * token1PriceUsd 
                                let point: Nat = _floatToNat(_natToFloat(Nat.sub(vol.value1, preVol.value1) * preMiningDataFactorPercent / 100) / _natToFloat(10 ** pairInfo.token1Decimals) * factorVipMaker * (1 + nftAcceRate) * token1PriceUsd);
                                _setVol(pairId, accountId, vol);
                                if (point > 0){
                                    addPointsForTM := Tools.arrayAppend(addPointsForTM, [(accountId, point)]);
                                };
                            };
                        };
                        let oamms = _getRoundOAMMs(roundId);
                        for ((pairId, oammId, shareDecimals, nav) in oamms.vals()){
                            let pairInfo = _getPairInfo(pairId);
                            let newTWSs = await* _fetchLiquidity(oammId);
                            for ((accountId, TWS) in newTWSs.vals()){
                                let preTWS: {shareTimeWeighted: Nat; updateTime: Timestamp} = _getTWShare(oammId, accountId);
                                let nftAcceRate: Float = _nftAcceRate(accountId);
                                let token1PriceUsd: Float = _getTokenPrice(pairInfo.token1.0);
                                // point = (TWS.shareTimeWeighted - preTWS.shareTimeWeighted) / 10**shareDecimals * nav.token1 / 10**token1.decimals * preMiningDataFactorPercent / 100 * (1 + nftAcceRate) * token1PriceUsd 
                                let point: Nat = _floatToNat(_natToFloat(Nat.sub(TWS.shareTimeWeighted, preTWS.shareTimeWeighted) * nav.token1 * preMiningDataFactorPercent / 100) / _natToFloat(10 ** shareDecimals) / _natToFloat(10 ** pairInfo.token1Decimals) * (1 + nftAcceRate) * token1PriceUsd);
                                _setTWShare(oammId, accountId, TWS);
                                if (point > 0){
                                    addPointsForLM := Tools.arrayAppend(addPointsForLM, [(accountId, point)]);
                                };
                            };
                        };
                        _updateRoundPoints(roundId, {addPointsForTM = addPointsForTM; addPointsForLM = addPointsForLM});
                        _updateRoundStatus(roundId, status);
                        // settle
                        if (status == #Settling){
                            _roundSettle(roundId);
                        };
                    };
                };
                case(_){};
            };
            isFetchingPoints := false;
        }catch(e){
            isFetchingPoints := false;
            throw e;
        };
    };

    private func _withdraw(_to: {owner: Principal; subaccount: ?Blob}): async* {#Ok: Nat; #Err: Text}{
        let accountId = Tools.principalToAccountBlob(_to.owner, _toSaNat8(_to.subaccount));
        let balance = _getBalance(accountId);
        let value = balance.available;
        if (value > tokenFee){
            try{
                _lockBalance(accountId, value);
                await* _transfer(_to, value);
                _sublockedBalance(accountId, value);
                return #Ok(Nat.sub(value, tokenFee));
            }catch(e){
                _unlockBalance(accountId, value);
                return #Err(Error.message(e));
            };
        }else{
            return #Err("Insufficient balance.");
        };
    };

    // ================== public functions ===================
    // manage
    public shared(msg) func changeOwner(_newOwner: Principal): async (){
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
    };
    public shared(msg) func changeToken(_newToken: Principal): async (){
        assert(_onlyOwner(msg.caller));
        token_ := _newToken;
    };
    public shared(msg) func newRound(_config: RoundConfig) : async RoundId{
        assert(_onlyOwner(msg.caller));
        var enCreation: Bool = true;
        switch(_getRound(null)){
            case(?round){
                if (round.status != #Closed){
                    enCreation := false;
                };
            };
            case(_){};
        };
        if (enCreation){
            let roundId = _newRound(_config);
            let now = _now();
            if (timerId > 0){
                Timer.cancelTimer(timerId);
            };
            timerFirstTaskStarted := false;
            if (_config.startTime == 0){
                timerTs := now + timerInterval;
            }else{
                timerTs := Nat.max(Nat.sub(_config.startTime, 5), now + 3);
            };
            timerId := Timer.setTimer(#seconds(Nat.sub(timerTs, now)), _fetchPoints);
            return roundId;
        }else{
            throw Error.reject("Cannot be created, as it was not completed in the previous round.");
        };
    };
    public shared(msg) func updateRound(_roundId: RoundId, _args: {
        pairs: ?{#whitelist: [PairId]; #all};
        pairFilter: ?{minPairScore: Nat; blackList: [PairId]};
        content: ?Text;
        startTime: ?Timestamp; // 0 means from the end of the previous round
        endTime: ?Timestamp;
        supplyForTM: ?Nat;
        supplyForLM: ?Nat;
        preMiningDataFactorPercent: ?Nat;
    }) : async (){
        assert(_onlyOwner(msg.caller));
        switch(_getRound(?_roundId)){
            case(?round){
                if (round.status == #Closed or round.status == #Settling){
                    throw Error.reject("The round cannot be modified.");
                };
                _updateRoundConfig(_roundId, _args);
                if (Option.isSome(_args.startTime) and not(timerFirstTaskStarted)){
                    let startTime = Option.get(_args.startTime, 0);
                    let now = _now();
                    if (timerId > 0){
                        Timer.cancelTimer(timerId);
                    };
                    if (startTime == 0){
                        timerTs := now + timerInterval;
                    }else{
                        timerTs := Nat.max(Nat.sub(startTime, 5), now + 3);
                    };
                    timerId := Timer.setTimer(#seconds(Nat.sub(timerTs, now)), _fetchPoints);
                };
            };
            case(_){
                throw Error.reject("The specified RoundId does not exist.");
            };
        };
    };

    // updates
    public shared func claim(_account: {owner: Principal; subaccount: ?Blob}) : async {#Ok: Nat; #Err: Text}{
        return await* _withdraw(_account);
    };
    // queries
    public query func getPairs(_page: ?Tools.ListPage, _size: ?Tools.ListSize) : async Tools.TrieList<PairId, PairInfo>{
        var trie = dexPairs;
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 1000);
        return Tools.trieItems(trie, page, size);
    };
    public query func getPrices(_page: ?Tools.ListPage, _size: ?Tools.ListSize) : async Tools.TrieList<Principal, (Float, Timestamp)>{
        var trie = tokenPrices;
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 1000);
        return Tools.trieItems(trie, page, size);
    };
    public query func getOAMMs(_page: ?Tools.ListPage, _size: ?Tools.ListSize) : async { page: Nat; totalPage: Nat; total: Nat; data: [(PairId, OammId, ShareDecimals, ICDexMaker.UnitNetValue)]}{
        let data = dexOAMMs;
        let pageSize = Option.get(_size, 100);
        let page = Option.get(_page, 1);
        let total = data.size();
        let totalPage: Nat = (total + Nat.sub(pageSize, 1)) / pageSize;
        let start: Nat = Nat.sub(page, 1) * pageSize;
        let end: Nat = start + Nat.sub(pageSize, 1);
        return { page = page; totalPage = totalPage; total = total; data = Tools.slice(data, start, ?end)};
    };
    public query func getVipMakers() : async [(PairId, AccountId)]{
        return vipMakers;
    };
    public query func getAccelerationRate(_accountId: AccountId) : async Float{
        return _nftAcceRate(_accountId);
    };
    public query func getNftHolders() : async [(AccountId, [ICDexRouter.NFT])]{
        return nftHolders;
    };
    public query func getBalance(_accountId: AccountId) : async {available: Nat; locked: Nat}{
        return _getBalance(_accountId);
    };
    public query func getRound(_roundId: ?RoundId) : async {round: RoundId; data: ?RoundDataReponse}{
        let roundId = Option.get(_roundId, roundCount);
        let data: ?RoundDataReponse = (switch(_getRound(?roundId)){
            case(?round){
                let accountPointsForTM = Tools.slice(Array.sort(Iter.toArray(Trie.iter(round.points.accountPointsForTM)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                    Nat.compare(y.1, x.1);
                }), 0, ?99);
                let accountPointsForLM = Tools.slice(Array.sort(Iter.toArray(Trie.iter(round.points.accountPointsForLM)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                    Nat.compare(y.1, x.1);
                }), 0, ?99);
                var settlementTM: [(AccountId, Nat)] = [];
                var settlementLM: [(AccountId, Nat)] = [];
                switch(round.settlement) {
                    case(?s) {
                        settlementTM := Tools.slice(Array.sort(Iter.toArray(Trie.iter(s.tm)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                    Nat.compare(y.1, x.1);
                }), 0, ?99);
                        settlementLM := Tools.slice(Array.sort(Iter.toArray(Trie.iter(s.lm)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                    Nat.compare(y.1, x.1);
                }), 0, ?99);
                    };
                    case(_) { };
                };
                ?{ 
                    config = round.config;
                    createdTime = round.createdTime;
                    status = round.status;
                    points = {
                        totalPointsForTM = round.points.totalPointsForTM; // The first 100.
                        totalPointsForLM = round.points.totalPointsForLM; // The first 100.
                        accountPointsForTM = accountPointsForTM;
                        accountPointsForLM = accountPointsForLM;
                        pointsUpdatedTime = round.points.pointsUpdatedTime;
                    };
                    settlement = ?{
                        tm = settlementTM; // The first 100.
                        lm = settlementLM; // The first 100.
                    } 
                };
            };
            case(_){ null };
        });
        return {
            round = roundId;
            data = data;
        };
    };
    public query func getRoundPointsForTM(_roundId: RoundId, _page: Nat/*base 1*/) : async { page: Nat; totalPage: Nat; total: Nat; data: [(AccountId, Nat)]}{
        let pageSize: Nat = 100;
        switch(_getRound(?_roundId)){
            case(?round){ 
                let data = Array.sort(Iter.toArray(Trie.iter(round.points.accountPointsForTM)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                    Nat.compare(y.1, x.1);
                });
                let total = data.size();
                let totalPage: Nat = (total + Nat.sub(pageSize, 1)) / pageSize;
                let start: Nat = Nat.sub(_page, 1) * pageSize;
                let end: Nat = start + Nat.sub(pageSize, 1);
                return { page = _page; totalPage = totalPage; total = total; data = Tools.slice(data, start, ?end)};
            };
            case(_){
                return { page = 0; totalPage = 0; total = 0; data = []};
            };
        };
    };
    public query func getRoundPointsForLM(_roundId: RoundId, _page: Nat/*base 1*/) : async { page: Nat; totalPage: Nat; total: Nat; data: [(AccountId, Nat)]}{
        let pageSize: Nat = 100;
        switch(_getRound(?_roundId)){
            case(?round){ 
                let data = Array.sort(Iter.toArray(Trie.iter(round.points.accountPointsForLM)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                    Nat.compare(y.1, x.1);
                });
                let total = data.size();
                let totalPage: Nat = (total + Nat.sub(pageSize, 1)) / pageSize;
                let start: Nat = Nat.sub(_page, 1) * pageSize;
                let end: Nat = start + Nat.sub(pageSize, 1);
                return { page = _page; totalPage = totalPage; total = total; data = Tools.slice(data, start, ?end)};
            };
            case(_){
                return { page = 0; totalPage = 0; total = 0; data = []};
            };
        };
    };
    public query func getRoundSettlementsForTM(_roundId: RoundId, _page: Nat/*base 1*/) : async { page: Nat; totalPage: Nat; total: Nat; data: [(AccountId, Nat)]}{
        let pageSize: Nat = 100;
        switch(_getRound(?_roundId)){
            case(?round){ 
                switch(round.settlement){
                    case(?settlement){
                        let data = Array.sort(Iter.toArray(Trie.iter(settlement.tm)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                            Nat.compare(y.1, x.1);
                        });
                        let total = data.size();
                        let totalPage: Nat = (total + Nat.sub(pageSize, 1)) / pageSize;
                        let start: Nat = Nat.sub(_page, 1) * pageSize;
                        let end: Nat = start + Nat.sub(pageSize, 1);
                        return { page = _page; totalPage = totalPage; total = total; data = Tools.slice(data, start, ?end)};
                    };
                    case(_){
                        return { page = 0; totalPage = 0; total = 0; data = []};
                    };
                };
            };
            case(_){
                return { page = 0; totalPage = 0; total = 0; data = []};
            };
        };
    };
    public query func getRoundSettlementsForLM(_roundId: RoundId, _page: Nat/*base 1*/) : async { page: Nat; totalPage: Nat; total: Nat; data: [(AccountId, Nat)]}{
        let pageSize: Nat = 100;
        switch(_getRound(?_roundId)){
            case(?round){ 
                switch(round.settlement){
                    case(?settlement){
                        let data = Array.sort(Iter.toArray(Trie.iter(settlement.lm)), func (x: (AccountId, Nat), y: (AccountId, Nat)): Order.Order{
                            Nat.compare(y.1, x.1);
                        });
                        let total = data.size();
                        let totalPage: Nat = (total + Nat.sub(pageSize, 1)) / pageSize;
                        let start: Nat = Nat.sub(_page, 1) * pageSize;
                        let end: Nat = start + Nat.sub(pageSize, 1);
                        return { page = _page; totalPage = totalPage; total = total; data = Tools.slice(data, start, ?end)};
                    };
                    case(_){
                        return { page = 0; totalPage = 0; total = 0; data = []};
                    };
                };
            };
            case(_){
                return { page = 0; totalPage = 0; total = 0; data = []};
            };
        };
    };
    public query func getAccountData(_roundId: ?RoundId, _accountId: AccountId) : async {
        round: RoundId; 
        roundStatus: {#Active; #Settling; #Closed}; 
        points: {tm: Nat; lm: Nat}; // USD  SWUSD
        settlement: ?{tm: Nat; lm: Nat}; // ICL
    }{
        let roundId = Option.get(_roundId, roundCount);
        var roundStatus: {#Active; #Settling; #Closed} = #Active;
        var points: {tm: Nat; lm: Nat} = {tm = 0; lm = 0};
        var settlement : ?{tm: Nat; lm: Nat} = null;
        switch(_getRound(?roundId)){
            case(?round){
                roundStatus := round.status;
                var pointsTM: Nat = 0;
                var pointsLM: Nat = 0;
                switch(Trie.get(round.points.accountPointsForTM, keyb(_accountId), Blob.equal)) {
                    case(?v) { pointsTM := v };
                    case(_) { };
                };
                switch(Trie.get(round.points.accountPointsForLM, keyb(_accountId), Blob.equal)) {
                    case(?v) { pointsLM := v };
                    case(_) { };
                };
                points := {tm = pointsTM; lm = pointsLM};
                switch(round.settlement){
                    case(?values){
                        var settlementTM: Nat = 0;
                        var settlementLM: Nat = 0;
                        switch(Trie.get(values.tm, keyb(_accountId), Blob.equal)) {
                            case(?v) { settlementTM := v };
                            case(_) { };
                        };
                        switch(Trie.get(values.lm, keyb(_accountId), Blob.equal)) {
                            case(?v) { settlementLM := v };
                            case(_) { };
                        };
                        settlement := ?{tm = settlementTM; lm = settlementLM};
                    };
                    case(_){};
                };
            };
            case(_){};
        };
        return {
            round = roundId; 
            roundStatus = roundStatus; 
            points = points; // USD  SWUSD
            settlement = settlement; // ICL
        };
    };
    public query func getVolLog(_pairId: PairId, _accountId: AccountId) : async ICDexPair.Vol{
        return _getVol(_pairId, _accountId);
    };
    public query func getTWShareLog(_oammId: OammId, _accountId: AccountId) : async ICDexMaker.ShareWeighted{
        return _getTWShare(_oammId, _accountId);
    };
    public query func info() : async {
        rewardToken: Principal;
        tokenFee: Nat;
        owner: Principal;
        roundCount: Nat;
        isFetchingPoints: Bool;
        timerId: Nat;
        timerTs: Timestamp;
        timerFirstTaskStarted: Bool;
        timerInterval: Timestamp;
    }{
        return {
            rewardToken = rewardToken;
            tokenFee = tokenFee;
            owner = owner;
            roundCount = roundCount;
            isFetchingPoints = isFetchingPoints;
            timerId = timerId;
            timerTs = timerTs;
            timerFirstTaskStarted = timerFirstTaskStarted;
            timerInterval = timerInterval;
        };
    };

    // ================== debugs ===================
    public shared(msg) func debug_fetchPairs() : async (){
        assert(_onlyOwner(msg.caller));
        await* _fetchPairs();
    };
    public shared(msg) func debug_fetchTokenPrices() : async (){
        assert(_onlyOwner(msg.caller));
        await* _fetchTokenPrices();
    };
    public shared(msg) func debug_fetchDexOAMMs() : async (){
        assert(_onlyOwner(msg.caller));
        await* _fetchPublicOAMMs();
    };
    public shared(msg) func debug_fetchVipMakers() : async (){
        assert(_onlyOwner(msg.caller));
        await* _fetchVipMakers();
    };
    public shared(msg) func debug_fetchNftHolders() : async (){
        assert(_onlyOwner(msg.caller));
        await* _fetchNftHolders();
    };
    public shared(msg) func debug_fetchPoints(_enforce: ?Bool) : async (){
        assert(_onlyOwner(msg.caller));
        if (_enforce == ?true) isFetchingPoints := false;
        await _fetchPoints();
    };
    public shared(msg) func debug_settle() : async (){
        assert(_onlyOwner(msg.caller));
        _roundSettle(roundCount);
    };
    public shared(msg) func debug_close() : async (){
        assert(_onlyOwner(msg.caller));
        _updateRoundStatus(roundCount, #Closed);
    };
    // ================== End: debugs ===================

    /* ===========================
      DRC207 section
    ============================== */
    // Default blackhole canister: 7hdtw-jqaaa-aaaak-aaccq-cai
    // ModuleHash(dfx: 0.8.4): 603692eda4a0c322caccaff93cf4a21dc44aebad6d71b40ecefebef89e55f3be
    // Github: https://github.com/iclighthouse/ICMonitor/blob/main/Blackhole.mo

    /// Returns the monitorability configuration of the canister.
    public query func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = true; canister_id = null; };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = null; }; 
        };
    };

    // /// canister_status
    // public shared(msg) func canister_status() : async DRC207.canister_status {
    //     // _sessionPush(msg.caller);
    //     // if (_tps(15, null).1 > setting.MAX_TPS*5 or _tps(15, ?msg.caller).0 > 2){ 
    //     //     assert(false); 
    //     // };
    //     let ic : DRC207.IC = actor("aaaaa-aa");
    //     await ic.canister_status({ canister_id = Principal.fromActor(this) });
    // };

    /// Receive cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let accepted = Cycles.accept(amout);
    };

    /// Withdraw cycles
    public shared(msg) func withdraw_cycles(_amount: Nat) : async (){
        assert(_onlyOwner(msg.caller));
        type Wallet = actor{ wallet_receive : shared () -> async (); };
        let wallet : Wallet = actor(Principal.toText(icdexRouter_));
        let amount = Cycles.balance();
        assert(_amount + 50_000_000_000 < amount);
        Cycles.add(_amount);
        await wallet.wallet_receive();
    };

    /* ===========================
      Timer section
    ============================== */
    private var recurringTimerId: Nat = 0;
    private var last_fetchPairs: Timestamp = 0;
    private var done_fetchPairs: Bool = true;
    private var last_fetchOAMMs: Timestamp = 0;
    private var done_fetchOAMMs: Bool = true;
    private var timerDoing: Bool = false;
    private func timerLoop() : async (){
        if (not(timerDoing)){
            timerDoing := true;
            if (_now() >= last_fetchPairs + 4 * 3600 and done_fetchPairs){
                last_fetchPairs := _now();
                done_fetchPairs := false;
                try{ await* _fetchPairs() }catch(e){};
                done_fetchPairs := true;
            };
            if (_now() >= last_fetchOAMMs + 4 * 3600 and done_fetchOAMMs){
                last_fetchOAMMs := _now();
                done_fetchOAMMs := false;
                try{ await* _fetchPublicOAMMs() }catch(e){};
                done_fetchOAMMs := true;
            };
            timerDoing := false;
        };
    };

    /// Start the Timer, it will be started automatically when upgrading the canister.
    public shared(msg) func timerStart(_intervalSeconds: Nat): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(recurringTimerId);
        recurringTimerId := Timer.recurringTimer(#seconds(_intervalSeconds), timerLoop);
    };

    /// Stop the Timer
    public shared(msg) func timerStop(): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(recurringTimerId);
    };

    system func preupgrade() {
        Timer.cancelTimer(timerId);
        Timer.cancelTimer(recurringTimerId);
    };

    system func postupgrade() {
        let now = _now();
        if (timerTs > 0){
            timerId := Timer.setTimer(#seconds(Nat.sub(Nat.max(timerTs, now + 5), now)), _fetchPoints);
        };
        recurringTimerId := Timer.recurringTimer(#seconds(900), timerLoop);
    };
};