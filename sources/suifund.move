module suifund::suifund;

use std::{ascii::String, type_name};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Self, Coin},
    display,
    dynamic_field as df,
    event::emit,
    package,
    sui::SUI,
    table::{Self, Table},
    table_vec::{Self, TableVec},
    url::{Self, Url}
};
use sui_system::{
    sui_system::{SuiSystemState, request_add_stake_non_entry, request_withdraw_stake_non_entry}
};
use suifund::{comment::{Self, Comment}, utils::{mul_div, get_remain_value}};

use protocol::{
    mint::mint as scallop_mint,
    redeem::redeem as scallop_redeem,
    market::Market as ScallopMarket,
    version::Version as ScallopVersion
};
use s_coin_converter::s_coin_converter::{
    SCoinTreasury,
    mint_s_coin,
    burn_s_coin
};

// ======== Constants =========
const VERSION: u64 = 1;
const THREE_DAYS_IN_MS: u64 = 259_200_000;
const SUI_BASE: u64 = 1_000_000_000;
const BASE_FEE: u64 = 20_000_000_000; // 20 SUI

// ======== Errors =========
const EInvalidStartTime: u64 = 1;
const EInvalidTimeInterval: u64 = 2;
const EInvalidRatio: u64 = 3;
const EInvalidSuiValue: u64 = 4;
const ETooLittle: u64 = 5;
const ENotStarted: u64 = 6;
// const EEnded: u64 = 7;
const ECapMismatch: u64 = 8;
const EAlreadyMax: u64 = 9;
const ENotSameProject: u64 = 10;
const ErrorAttachDFExists: u64 = 11;
const EInvalidAmount: u64 = 12;
const ENotSplitable: u64 = 13;
const EProjectCanceled: u64 = 14;
const ENotBurnable: u64 = 15;
const EVersionMismatch: u64 = 16;
const EImproperRatio: u64 = 17;
const EProjectNotCanceled: u64 = 18;
const ETakeAwayNotCompleted: u64 = 19;
const EInvalidThresholdRatio: u64 = 20;
const ENotBegin: u64 = 21;
// const EAlreadyBegin: u64 = 22;
const ENotCanceled: u64 = 23;
const ENoRemain: u64 = 24;

// ======== Types =========

public struct SUIFUND has drop {}

public struct DeployRecord has key {
    id: UID,
    record: Table<String, ID>,
    categories: Table<String, Table<String, ID>>,  // Typo, categories
    balance: Balance<SUI>,
    base_fee: u64,
    ratio: u64,
}

public struct ProjectRecord has key {
    id: UID,
    creator: address,
    name: String,
    description: std::string::String,
    category: String,
    image_url: Url,
    linktree: Url,
    x: Url,
    telegram: Url,
    discord: Url,
    website: Url,
    github: Url,
    cancel: bool,
    balance: Balance<SUI>,
    ratio: u64,
    start_time_ms: u64,
    end_time_ms: u64,
    total_supply: u64,
    amount_per_sui: u64,
    remain: u64,
    current_supply: u64,
    total_transactions: u64,
    threshold_ratio: u64,
    begin: bool,
    min_value_sui: u64,
    max_value_sui: u64,
    participants: TableVec<address>,
    minted_per_user: Table<address, u64>,
    thread: TableVec<Comment>,
}

public struct Version has key {
    id: UID,
    version: u64,
}

public struct ProjectAdminCap has key, store {
    id: UID,
    to: ID,
}

public struct AdminCap has key, store {
    id: UID,
}

public struct SupporterReward has key, store {
    id: UID,
    name: String,
    project_id: ID,
    image: Url,
    amount: u64,
    balance: Balance<SUI>,
    start: u64,
    end: u64,
    attach_df: u8,
}

// ======== Events =========
public struct DeployEvent has copy, drop {
    project_id: ID,
    project_name: String,
    deployer: address,
    deploy_fee: u64,
}

public struct EditProject has copy, drop {
    project_name: String,
    editor: address,
}

public struct MintEvent has copy, drop {
    project_name: String,
    project_id: ID,
    sender: address,
    amount: u64,
}

public struct BurnEvent has copy, drop {
    project_name: String,
    project_id: ID,
    sender: address,
    amount: u64,
    withdraw_value: u64,
    inside_value: u64,
}

public struct ReferenceReward has copy, drop {
    sender: address,
    recipient: address,
    value: u64,
    project: ID,
}

public struct ClaimStreamPayment has copy, drop {
    project_name: String,
    sender: address,
    value: u64,
}

public struct CancelProjectEvent has copy, drop {
    project_name: String,
    project_id: ID,
    sender: address,
}

// ======== Functions =========
fun init(otw: SUIFUND, ctx: &mut TxContext) {
    let deployer = ctx.sender();
    let deploy_record = DeployRecord {
        id: object::new(ctx),
        record: table::new(ctx),
        categories: table::new(ctx),
        balance: balance::zero<SUI>(),
        base_fee: BASE_FEE,
        ratio: 1,
    };
    transfer::share_object(deploy_record);
    let version = Version { id: object::new(ctx), version: VERSION };
    transfer::share_object(version);
    let admin_cap = AdminCap { id: object::new(ctx) };
    transfer::public_transfer(admin_cap, deployer);

    let keys = vector[
        b"name".to_string(),
        b"image_url".to_string(),
        b"project_url".to_string(),
        b"market_url".to_string(),
        b"coinswap_url".to_string(),
        b"start".to_string(),
        b"end".to_string(),
        b"alert".to_string(),
    ];

    let mut image_url: vector<u8> = b"https://suistarter.app/objectId/";
    image_url.append(b"{id}");

    let mut project_url: vector<u8> = b"https://suistarter.app/project/";
    project_url.append(b"{project_id}");
    let mut market_url: vector<u8> = b"https://suistarter.app/market/";
    market_url.append(b"{project_id}");
    let mut coinswap_url: vector<u8> = b"https://suistarter.app/coinswap/";
    coinswap_url.append(b"{project_id}");
    let values = vector[
        b"Supporter Ticket".to_string(),
        image_url.to_string(),
        project_url.to_string(),
        market_url.to_string(),
        coinswap_url.to_string(),
        b"{start}".to_string(),
        b"{end}".to_string(),
        b"!!!Do not visit any links in the pictures, as they may be SCAMs.".to_string(),
    ];

    let publisher = package::claim(otw, ctx);
    let mut display = display::new_with_fields<SupporterReward>(
        &publisher,
        keys,
        values,
        ctx,
    );

    display.update_version();
    transfer::public_transfer(publisher, deployer);
    transfer::public_transfer(display, deployer);
}

// ======= Deploy functions ========

public fun get_deploy_fee(
    total_deposit_sui: u64,
    base_fee: u64,
    project_ratio: u64,
    deploy_ratio: u64,
): u64 {
    assert!(deploy_ratio <= 5, EImproperRatio);
    let mut cal_value: u64 = mul_div(total_deposit_sui, project_ratio, 100);
    cal_value = mul_div(cal_value, deploy_ratio, 100);
    let fee_value: u64 = if (cal_value > base_fee) {
        cal_value
    } else {
        base_fee
    };
    fee_value
}

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): ProjectAdminCap`
public fun deploy(
    deploy_record: &mut DeployRecord,
    name: vector<u8>,
    description: vector<u8>,
    category: vector<u8>,
    image_url: vector<u8>,
    linktree: vector<u8>,
    x: vector<u8>,
    telegram: vector<u8>,
    discord: vector<u8>,
    website: vector<u8>,
    github: vector<u8>,
    start_time_ms: u64,
    time_interval: u64,
    total_deposit_sui: u64,
    ratio: u64,
    amount_per_sui: u64,
    threshold_ratio: u64,
    min_value_sui: u64,
    max_value_sui: u64,
    fee: &mut Coin<SUI>,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let project_admin_cap = deploy_non_entry(
        deploy_record,
        name,
        description,
        category,
        image_url,
        linktree,
        x,
        telegram,
        discord,
        website,
        github,
        start_time_ms,
        time_interval,
        total_deposit_sui,
        ratio,
        amount_per_sui,
        threshold_ratio,
        min_value_sui,
        max_value_sui,
        fee,
        version,
        clock,
        ctx,
    );
    transfer::public_transfer(project_admin_cap, ctx.sender());
}

public fun deploy_non_entry(
    deploy_record: &mut DeployRecord,
    name: vector<u8>,
    description: vector<u8>,
    category: vector<u8>,
    image_url: vector<u8>,
    linktree: vector<u8>,
    x: vector<u8>,
    telegram: vector<u8>,
    discord: vector<u8>,
    website: vector<u8>,
    github: vector<u8>,
    start_time_ms: u64,
    time_interval: u64,
    total_deposit_sui: u64,
    ratio: u64,
    amount_per_sui: u64,
    threshold_ratio: u64,
    min_value_sui: u64,
    max_value_sui: u64,
    fee: &mut Coin<SUI>,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
): ProjectAdminCap {
    assert!(version.version == VERSION, EVersionMismatch);
    let sender = ctx.sender();
    let now = clock.timestamp_ms();
    assert!(start_time_ms >= now, EInvalidStartTime);
    assert!(time_interval >= THREE_DAYS_IN_MS, EInvalidTimeInterval);
    assert!(ratio <= 100, EInvalidRatio);
    assert!(threshold_ratio <= 100, EInvalidThresholdRatio);
    assert!(min_value_sui >= SUI_BASE, ETooLittle);
    assert!(amount_per_sui >= 1, ETooLittle);
    if (max_value_sui != 0) {
        assert!(min_value_sui <= max_value_sui, EInvalidSuiValue);
    };

    let deploy_fee = get_deploy_fee(
        total_deposit_sui,
        deploy_record.base_fee,
        ratio,
        deploy_record.ratio,
    );

    // charge deploy fee
    deploy_record.balance.join(fee.balance_mut().split(deploy_fee));

    let category = category.to_ascii_string();
    let total_supply = total_deposit_sui / SUI_BASE * amount_per_sui;
    let project_name = name.to_ascii_string();
    let project_record = ProjectRecord {
        id: object::new(ctx),
        creator: sender,
        name: project_name,
        description: description.to_string(),
        category,
        image_url: image_url.to_url(),
        linktree: linktree.to_url(),
        x: x.to_url(),
        telegram: telegram.to_url(),
        discord: discord.to_url(),
        website: website.to_url(),
        github: github.to_url(),
        cancel: false,
        balance: balance::zero(),
        ratio,
        start_time_ms,
        end_time_ms: start_time_ms + time_interval,
        total_supply,
        amount_per_sui,
        remain: total_supply,
        current_supply: 0,
        total_transactions: 0,
        threshold_ratio,
        begin: false,
        min_value_sui,
        max_value_sui,
        participants: table_vec::empty(ctx),
        minted_per_user: table::new(ctx),
        thread: table_vec::empty(ctx),
    };

    let project_id = object::id(&project_record);
    let project_admin_cap = ProjectAdminCap {
        id: object::new(ctx),
        to: project_id,
    };

    deploy_record.record.add(project_name, project_id);

    if (category.length() > 0) {
        if (deploy_record.categories.contains(category)) {
            deploy_record.categories[category].add(project_name, project_id);
        } else {
            let mut category_record = table::new(ctx);
            category_record.add(project_name, project_id);
            deploy_record.categories.add(category, category_record);
        };
    };

    transfer::share_object(project_record);

    emit(DeployEvent {
        project_id,
        project_name,
        deployer: sender, // TODO: no need, sender is already present in every event
        deploy_fee,
    });

    project_admin_cap
}

// ======= Claim functions ========

public fun do_claim(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(version.version == VERSION, EVersionMismatch);
    assert!(project_record.begin, ENotBegin);
    check_project_cap(project_record, project_admin_cap);
    assert!(!project_record.cancel, EProjectCanceled);

    let now = clock.timestamp_ms();
    let mut init_value = mul_div(
        project_record.current_supply,
        SUI_BASE,
        project_record.amount_per_sui,
    );
    init_value = init_value * project_record.ratio / 100;
    let remain_value = get_remain_value(
        init_value,
        project_record.start_time_ms,
        project_record.end_time_ms,
        now,
    );
    let claim_value = project_record.balance.value() - remain_value;

    emit(ClaimStreamPayment {
        project_name: project_record.name,
        sender: ctx.sender(), // TODO: no need, sender is already present in every event
        value: claim_value,
    });

    project_record.balance.split(claim_value).into_coin(ctx)
}

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): Coin<SUI>`
public fun claim(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let claim_coin = do_claim(project_record, project_admin_cap, version, clock, ctx);
    transfer::public_transfer(claim_coin, ctx.sender());
}

// ======= Mint functions ========

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): Coin<SUI>`
public fun mint(
    project_record: &mut ProjectRecord,
    fee_sui: &mut Coin<SUI>,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let supporter_reward = do_mint(project_record, fee_sui, version, clock, ctx);
    transfer::public_transfer(supporter_reward, ctx.sender());
}

public fun do_mint(
    project_record: &mut ProjectRecord,
    fee_sui: &mut Coin<SUI>,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
): SupporterReward {
    let sender = ctx.sender();
    let now = clock.timestamp_ms();
    assert!(now >= project_record.start_time_ms, ENotStarted);
    // assert!(now <= project_record.end_time_ms, EEnded);
    assert!(version.version == VERSION, EVersionMismatch);
    assert!(!project_record.cancel, EProjectCanceled);
    assert!(project_record.remain > 0, ENoRemain);

    let mut sui_value = fee_sui.value();
    assert!(sui_value >= project_record.min_value_sui, ETooLittle);

    if (project_record.minted_per_user.contains(sender)) {
        let minted_value = &mut project_record.minted_per_user[sender];
        if (
            project_record.max_value_sui > 0 &&
            sui_value + *minted_value > project_record.max_value_sui
        ) {
            sui_value = project_record.max_value_sui - *minted_value;
        };
        assert!(sui_value > 0, EAlreadyMax);
        *minted_value = *minted_value + sui_value;
    } else {
        if (project_record.max_value_sui > 0 && sui_value > project_record.max_value_sui) {
            sui_value = project_record.max_value_sui;
        };
        project_record.minted_per_user.add(sender, sui_value);
        project_record.participants.push_back(sender);
    };

    let mut amount: u64 = mul_div(sui_value, project_record.amount_per_sui, SUI_BASE);

    if (amount >= project_record.remain) {
        amount = project_record.remain;
        sui_value = mul_div(amount, SUI_BASE, project_record.amount_per_sui);
    };

    project_record.remain = project_record.remain - amount;
    project_record.current_supply = project_record.current_supply + amount;
    project_record.total_transactions = project_record.total_transactions + 1;

    let project_sui_value = sui_value * project_record.ratio / 100;
    let locked_sui_value = sui_value * (100 - project_record.ratio) / 100;

    project_record.balance.join(fee_sui.balance_mut().split(project_sui_value));

    if (
        !project_record.begin &&
        project_record.current_supply >=
        mul_div(project_record.total_supply, project_record.threshold_ratio, 100)
    ) {
        project_record.begin = true;
    };

    let project_id = object::id(project_record);

    emit(MintEvent {
        project_name: project_record.name,
        project_id,
        sender,
        amount,
    });

    let locked_sui = fee_sui.balance_mut().split(locked_sui_value);

    new_supporter_reward(
        project_record.name,
        project_id,
        project_record.image_url,
        amount,
        locked_sui,
        project_record.start_time_ms,
        project_record.end_time_ms,
        ctx,
    )
}

public fun reference_reward(
    reward: Coin<SUI>,
    sender: address,
    recipient: address,
    project_record: &ProjectRecord,
) {
    emit(ReferenceReward {
        sender,
        recipient,
        value: coin::value<SUI>(&reward),
        project: object::id(project_record),
    });
    transfer::public_transfer(reward, recipient);
}

// ======= Merge functions ========

public fun do_merge(sp_rwd_1: &mut SupporterReward, sp_rwd_2: SupporterReward) {
    assert!(sp_rwd_1.name == sp_rwd_2.name, ENotSameProject);
    assert!(sp_rwd_2.attach_df == 0, ErrorAttachDFExists);

    let SupporterReward { id, amount, balance, .. } = sp_rwd_2;
    sp_rwd_1.amount = sp_rwd_1.amount + amount;
    sp_rwd_1.balance.join(balance);
    id.delete()
}

public fun merge(sp_rwd_1: &mut SupporterReward, sp_rwd_2: SupporterReward) {
    do_merge(sp_rwd_1, sp_rwd_2);
}

// ======= Split functions ========

public fun is_splitable(sp_rwd: &SupporterReward): bool {
    sp_rwd.amount > 1 && sp_rwd.attach_df == 0
}

public fun do_split(
    sp_rwd: &mut SupporterReward,
    amount: u64,
    ctx: &mut TxContext,
): SupporterReward {
    assert!(0 < amount && amount < sp_rwd.amount, EInvalidAmount);
    assert!(is_splitable(sp_rwd), ENotSplitable);

    let sui_value = sp_rwd.balance.value();

    let mut new_sui_value = mul_div(sui_value, amount, sp_rwd.amount);
    if (new_sui_value == 0) {
        new_sui_value = 1;
    };

    let new_sui_balance = sp_rwd.balance.split(new_sui_value);
    sp_rwd.amount = sp_rwd.amount - amount;

    new_supporter_reward(
        sp_rwd.name,
        sp_rwd.project_id,
        sp_rwd.image,
        amount,
        new_sui_balance,
        sp_rwd.start,
        sp_rwd.end,
        ctx,
    )
}

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): SupporterReward`
public fun split(sp_rwd: &mut SupporterReward, amount: u64, ctx: &mut TxContext) {
    let new_sp_rwd = do_split(sp_rwd, amount, ctx);
    transfer::public_transfer(new_sp_rwd, ctx.sender());
}

// ======= Burn functions ========

public fun do_burn(
    project_record: &mut ProjectRecord,
    sp_rwd: SupporterReward,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(object::id(project_record) == sp_rwd.project_id, ENotSameProject);
    assert!(version.version == VERSION, EVersionMismatch);
    assert!(sp_rwd.attach_df == 0, ENotBurnable);

    let sender = ctx.sender();
    let now = clock.timestamp_ms();

    let total_value = if (project_record.cancel || !project_record.begin) {
        project_record.balance.value()
    } else {
        get_remain_value(
            mul_div(project_record.current_supply, SUI_BASE, project_record.amount_per_sui),
            project_record.start_time_ms,
            project_record.end_time_ms,
            now,
        ) * project_record.ratio /
        100
    };

    let withdraw_value = mul_div(total_value, sp_rwd.amount, project_record.current_supply);
    let inside_value = sp_rwd.balance.value();

    project_record.current_supply = project_record.current_supply - sp_rwd.amount;
    project_record.remain = project_record.remain + sp_rwd.amount;
    let sender_minted = &mut project_record.minted_per_user[sender];
    if (*sender_minted >= sp_rwd.amount) {
        *sender_minted = *sender_minted - sp_rwd.amount;
    };

    let SupporterReward {
        id,
        name,
        project_id,
        amount,
        balance,
        ..,
    } = sp_rwd;

    let mut withdraw_balance: Balance<SUI> = project_record.balance.split(withdraw_value);
    withdraw_balance.join(balance);
    id.delete();

    emit(BurnEvent {
        project_name: name,
        project_id,
        sender,
        amount,
        withdraw_value,
        inside_value,
    });

    withdraw_balance.into_coin(ctx)
}

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): Coin<SUI>`
public fun burn(
    project_record: &mut ProjectRecord,
    sp_rwd: SupporterReward,
    version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let withdraw_coin = do_burn(project_record, sp_rwd, version, clock, ctx);
    transfer::public_transfer(withdraw_coin, ctx.sender());
}

// ======= Native Stake functions ========

public fun native_stake(
    wrapper: &mut SuiSystemState,
    validator_address: address,
    sp_rwd: &mut SupporterReward,
    ctx: &mut TxContext,
) {
    let to_stake: Coin<SUI> = sp_rwd.balance.withdraw_all().into_coin(ctx);
    let staked_sui = request_add_stake_non_entry(wrapper, to_stake, validator_address, ctx);
    add_df_with_name(sp_rwd, b"native".to_string(), staked_sui);
}

public fun native_unstake(
    wrapper: &mut SuiSystemState,
    sp_rwd: &mut SupporterReward,
    ctx: &mut TxContext,
) {
    // assert staked before
    let staked_sui = remove_df_with_name(sp_rwd, b"native".to_string());
    let sui = request_withdraw_stake_non_entry(wrapper, staked_sui, ctx);
    sp_rwd.balance.join(sui);
}

// ======= Scallop Stake functions ========

public fun scallop_stake<ST>(
    version: &ScallopVersion,
    market: &mut ScallopMarket,
    treasury: &mut SCoinTreasury<ST, SUI>,
    sp_rwd: &mut SupporterReward,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let to_stake: Coin<SUI> = sp_rwd.balance.withdraw_all().into_coin(ctx);
    let market_coin = scallop_mint<SUI>(version, market, to_stake, clock, ctx);
    let scoin = mint_s_coin<ST, SUI>(treasury, market_coin, ctx);
    add_df_with_name(sp_rwd, b"scallop".to_string(), scoin);
}

public fun scallop_unstake<ST>(
    version: &ScallopVersion,
    market: &mut ScallopMarket,
    treasury: &mut SCoinTreasury<ST, SUI>,
    sp_rwd: &mut SupporterReward,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // assert staked to scallop before
    let scallop_sui = remove_df_with_name(sp_rwd, b"scallop".to_string());
    let market_coin = burn_s_coin<ST, SUI>(treasury, scallop_sui, ctx);
    let coin = scallop_redeem(version, market, market_coin, clock, ctx);
    sp_rwd.balance.join(coin.into_balance());
}

// ======= Edit ProjectRecord functions ========

public fun add_comment(
    project_record: &mut ProjectRecord,
    reply: Option<ID>,
    media_link: vector<u8>,
    content: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let comment = comment::new_comment(reply, media_link, content, clock, ctx);
    project_record.thread.push_back(comment);
}

public fun like_comment(project_record: &mut ProjectRecord, idx: u64, ctx: &TxContext) {
    project_record.thread[idx].like_comment(ctx);
}

public fun unlike_comment(project_record: &mut ProjectRecord, idx: u64, ctx: &TxContext) {
    project_record.thread[idx].unlike_comment(ctx);
}

public fun edit_description(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    description: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.description = description.to_string();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_image_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    image_url: vector<u8>,
    deploy_record: &mut DeployRecord,
    paid: &mut Coin<SUI>,
    ctx: &mut TxContext,
) {
    check_project_cap(project_record, project_admin_cap);

    let edit_coin = coin::split<SUI>(paid, SUI_BASE / 10, ctx);
    balance::join<SUI>(&mut deploy_record.balance, coin::into_balance<SUI>(edit_coin));

    project_record.image_url = image_url.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_linktree_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    linktree: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.linktree = linktree.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_x_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    x_url: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.x = x_url.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_telegram_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    telegram_url: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.telegram = telegram_url.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_discord_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    discord_url: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.discord = discord_url.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_website_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    website_url: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.website = website_url.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun edit_github_url(
    project_record: &mut ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
    github_url: vector<u8>,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    project_record.github = github_url.to_url();
    emit(EditProject {
        project_name: project_record.name,
        editor: ctx.sender(),
    });
}

public fun cancel_project_by_team(
    project_admin_cap: &ProjectAdminCap,
    deploy_record: &mut DeployRecord,
    project_record: &mut ProjectRecord,
    version: &Version,
    ctx: &TxContext,
) {
    check_project_cap(project_record, project_admin_cap);
    assert!(version.version == VERSION, EVersionMismatch);
    cancel_project(deploy_record, project_record, ctx);
}

public fun burn_project_admin_cap(
    project_record: &mut ProjectRecord,
    project_admin_cap: ProjectAdminCap,
) {
    check_project_cap(project_record, &project_admin_cap);
    assert!(project_record.cancel, ENotCanceled);
    let ProjectAdminCap { id, to: _ } = project_admin_cap;
    id.delete();
}

// ======= ProjectRecord Get functions ========

public fun project_name(project_record: &ProjectRecord): String {
    project_record.name
}

public fun project_description(project_record: &ProjectRecord): std::string::String {
    project_record.description
}

public fun project_image_url(project_record: &ProjectRecord): Url {
    project_record.image_url
}

public fun project_linktree_url(project_record: &ProjectRecord): Url {
    project_record.linktree
}

public fun project_x_url(project_record: &ProjectRecord): Url {
    project_record.x
}

public fun project_telegram_url(project_record: &ProjectRecord): Url {
    project_record.telegram
}

public fun project_discord_url(project_record: &ProjectRecord): Url {
    project_record.discord
}

public fun project_website_url(project_record: &ProjectRecord): Url {
    project_record.website
}

public fun project_github_url(project_record: &ProjectRecord): Url {
    project_record.github
}

public fun project_balance_value(project_record: &ProjectRecord): u64 {
    balance::value<SUI>(&project_record.balance)
}

public fun project_ratio(project_record: &ProjectRecord): u64 {
    project_record.ratio
}

public fun project_start_time_ms(project_record: &ProjectRecord): u64 {
    project_record.start_time_ms
}

public fun project_end_time_ms(project_record: &ProjectRecord): u64 {
    project_record.end_time_ms
}

public fun project_total_supply(project_record: &ProjectRecord): u64 {
    project_record.total_supply
}

public fun project_amount_per_sui(project_record: &ProjectRecord): u64 {
    project_record.amount_per_sui
}

public fun project_remain(project_record: &ProjectRecord): u64 {
    project_record.remain
}

public fun project_current_supply(project_record: &ProjectRecord): u64 {
    project_record.current_supply
}

public fun project_total_transactions(project_record: &ProjectRecord): u64 {
    project_record.total_transactions
}

public fun project_begin_status(project_record: &ProjectRecord): bool {
    project_record.begin
}

public fun project_threshold_ratio(project_record: &ProjectRecord): u64 {
    project_record.threshold_ratio
}

public fun project_min_value_sui(project_record: &ProjectRecord): u64 {
    project_record.min_value_sui
}

public fun project_max_value_sui(project_record: &ProjectRecord): u64 {
    project_record.max_value_sui
}

public fun project_participants_number(project_record: &ProjectRecord): u64 {
    table_vec::length<address>(&project_record.participants)
}

public fun project_participants(project_record: &ProjectRecord): &TableVec<address> {
    &project_record.participants
}

public fun project_minted_per_user(project_record: &ProjectRecord): &Table<address, u64> {
    &project_record.minted_per_user
}

public fun project_thread(project_record: &ProjectRecord): &TableVec<Comment> {
    &project_record.thread
}

public fun project_admin_cap_to(project_admin_cap: &ProjectAdminCap): ID {
    project_admin_cap.to
}

// ======= Admin functions ========
// In case of ProjectAdminCap is lost
public fun cancel_project_by_admin(
    _: &AdminCap,
    deploy_record: &mut DeployRecord,
    project_record: &mut ProjectRecord,
    ctx: &TxContext,
) {
    cancel_project(deploy_record, project_record, ctx);
}

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): Coin<SUI>`
public fun take_remain(_: &AdminCap, project_record: &mut ProjectRecord, ctx: &mut TxContext) {
    assert!(project_record.cancel, EProjectNotCanceled);
    assert!(project_record.current_supply == 0, ETakeAwayNotCompleted);
    let sui_value = project_record.balance.value();
    let remain = project_record.balance.split(sui_value).into_coin(ctx);
    transfer::public_transfer(remain, ctx.sender());
}

public fun set_base_fee(_: &AdminCap, deploy_record: &mut DeployRecord, base_fee: u64) {
    deploy_record.base_fee = base_fee;
}

public fun set_ratio(_: &AdminCap, deploy_record: &mut DeployRecord, ratio: u64) {
    assert!(ratio <= 5, EImproperRatio);
    deploy_record.ratio = ratio;
}

#[allow(lint(self_transfer))]
// TODO: create a composable version which returns `(): Coin<SUI>`
public fun withdraw_balance(
    _: &AdminCap,
    deploy_record: &mut DeployRecord,
    ctx: &mut TxContext,
) {
    let sui_value = deploy_record.balance.value();
    let coin = deploy_record.balance.split(sui_value).into_coin(ctx);
    transfer::public_transfer(coin, ctx.sender());
}

// ======= SupporterReward Get functions ========
public fun sr_name(sp_rwd: &SupporterReward): String {
    sp_rwd.name
}

public fun sr_project_id(sp_rwd: &SupporterReward): ID {
    sp_rwd.project_id
}

public fun sr_image(sp_rwd: &SupporterReward): Url {
    sp_rwd.image
}

public fun sr_amount(sp_rwd: &SupporterReward): u64 {
    sp_rwd.amount
}

public fun sr_balance_value(sp_rwd: &SupporterReward): u64 {
    balance::value<SUI>(&sp_rwd.balance)
}

public fun sr_start_time_ms(sp_rwd: &SupporterReward): u64 {
    sp_rwd.start
}

public fun sr_end_time_ms(sp_rwd: &SupporterReward): u64 {
    sp_rwd.end
}

public fun sr_attach_df_num(sp_rwd: &SupporterReward): u8 {
    sp_rwd.attach_df
}

public fun update_image(
    project_record: &ProjectRecord,
    supporter_reward: &mut SupporterReward,
) {
    assert!(project_record.name == supporter_reward.name, ENotSameProject);
    supporter_reward.image = project_record.image_url;
}

public fun check_project_cap(
    project_record: &ProjectRecord,
    project_admin_cap: &ProjectAdminCap,
) {
    assert!(object::id(project_record) == project_admin_cap.to, ECapMismatch);
}

public(package) fun add_df_in_project<Name: copy + drop + store, Value: store>(
    project_record: &mut ProjectRecord,
    name: Name,
    value: Value,
) {
    df::add(&mut project_record.id, name, value);
}

public(package) fun remove_df_in_project<Name: copy + drop + store, Value: store>(
    project_record: &mut ProjectRecord,
    name: Name,
): Value {
    df::remove<Name, Value>(&mut project_record.id, name)
}

#[syntax(index)]
public(package) fun borrow_in_project<Name: copy + drop + store, Value: store>(
    project_record: &ProjectRecord,
    name: Name,
): &Value {
    df::borrow(&project_record.id, name)
}

#[syntax(index)]
public(package) fun borrow_mut_in_project<Name: copy + drop + store, Value: store>(
    project_record: &mut ProjectRecord,
    name: Name,
): &mut Value {
    df::borrow_mut(&mut project_record.id, name)
}

public(package) fun exists_in_project<Name: copy + drop + store>(
    project_record: &ProjectRecord,
    name: Name,
): bool {
    df::exists_(&project_record.id, name)
}

fun add_df_with_name<Name: copy + drop + store, Value: store>(sp_rwd: &mut SupporterReward, name: Name, value: Value) {
    assert!(sp_rwd.attach_df == 0);
    sp_rwd.attach_df = sp_rwd.attach_df + 1;
    df::add(&mut sp_rwd.id, name, value);
}

fun remove_df_with_name<Name: copy + drop + store, Value: store>(sp_rwd: &mut SupporterReward, name: Name): Value {
    // assert attach_df > 0
    sp_rwd.attach_df = sp_rwd.attach_df - 1;
    df::remove(&mut sp_rwd.id, name)
}

#[allow(unused_function)]
fun exists_df<Value: store>(sp_rwd: &SupporterReward): bool {
    let name = type_name::get_with_original_ids<Value>().into_string();
    df::exists_with_type<_, Value>(&sp_rwd.id, name)
}

fun new_supporter_reward(
    name: String,
    project_id: ID,
    image: Url,
    amount: u64,
    balance: Balance<SUI>,
    start: u64,
    end: u64,
    ctx: &mut TxContext,
): SupporterReward {
    SupporterReward {
        id: object::new(ctx),
        name,
        project_id,
        image,
        amount,
        balance,
        start,
        end,
        attach_df: 0,
    }
}

fun cancel_project(
    deploy_record: &mut DeployRecord,
    project_record: &mut ProjectRecord,
    ctx: &TxContext,
) {
    // assert!(!project_record.begin, EAlreadyBegin);
    project_record.cancel = true;

    let project_id = deploy_record.record.remove(project_record.name);
    if (project_record.category.length() > 0) {
        let category_record_bm = &mut deploy_record.categories[project_record.category];
        category_record_bm.remove(project_record.name);
        if (category_record_bm.is_empty()) {
            deploy_record.categories.remove(project_record.category).destroy_empty();
        };
    };

    emit(CancelProjectEvent {
        project_name: project_record.name,
        project_id,
        sender: ctx.sender(),
    });
}

// ========= Test Functions =========

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(SUIFUND {}, ctx);
}

#[test_only]
public fun new_sp_rwd_for_testing(
    name: String,
    project_id: ID,
    image: Url,
    amount: u64,
    balance: Balance<SUI>,
    start: u64,
    end: u64,
    ctx: &mut TxContext,
): SupporterReward {
    new_supporter_reward(name, project_id, image, amount, balance, start, end, ctx)
}

#[test_only]
public fun drop_sp_rwd_for_testing(sp_rwd: SupporterReward) {
    let SupporterReward { id, balance, .. } = sp_rwd;
    balance.destroy_for_testing();
    id.delete();
}

#[test_only]
public fun new_project_record_for_testing(
    name: vector<u8>,
    description: vector<u8>,
    category: vector<u8>,
    image_url: vector<u8>,
    linktree: vector<u8>,
    x: vector<u8>,
    telegram: vector<u8>,
    discord: vector<u8>,
    website: vector<u8>,
    github: vector<u8>,
    ratio: u64,
    start_time_ms: u64,
    time_interval: u64,
    total_deposit_sui: u64,
    amount_per_sui: u64,
    threshold_ratio: u64,
    min_value_sui: u64,
    max_value_sui: u64,
    ctx: &mut TxContext,
): ProjectRecord {
    let total_supply = total_deposit_sui / SUI_BASE * amount_per_sui;
    ProjectRecord {
        id: object::new(ctx),
        creator: ctx.sender(),
        name: std::ascii::string(name),
        description: std::string::utf8(description),
        category: std::ascii::string(category),
        image_url: image_url.to_url(),
        linktree: linktree.to_url(),
        x: x.to_url(),
        telegram: telegram.to_url(),
        discord: discord.to_url(),
        website: website.to_url(),
        github: github.to_url(),
        cancel: false,
        balance: balance::zero(),
        ratio,
        start_time_ms,
        end_time_ms: start_time_ms + time_interval,
        total_supply,
        amount_per_sui,
        remain: total_supply,
        current_supply: 0,
        total_transactions: 0,
        threshold_ratio,
        begin: false,
        min_value_sui,
        max_value_sui,
        participants: table_vec::empty<address>(ctx),
        minted_per_user: table::new<address, u64>(ctx),
        thread: table_vec::empty<Comment>(ctx),
    }
}

#[test_only]
public fun drop_project_record_for_testing(project_record: ProjectRecord) {
    let ProjectRecord {
        id,
        balance,
        mut thread,
        participants,
        minted_per_user,
        ..,
    } = project_record;

    balance.destroy_for_testing();
    participants.drop();
    minted_per_user.drop();

    thread.length().do!(|_| thread.pop_back().drop_comment());

    thread.destroy_empty();
    id.delete();
}

// ========= Aliases =======

use fun url::new_unsafe_from_bytes as vector.to_url;
