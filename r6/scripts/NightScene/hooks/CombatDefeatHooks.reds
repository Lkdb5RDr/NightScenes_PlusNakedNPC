// NightScene Framework - Combat Defeat Hooks
// ==============================================
// Player defeat: NightSceneHealthMonitor polls the player's health every
// 0.1s and intercepts once it drops to/below config.defeatHealthThreshold,
// BEFORE the player's Death state machine transition is ever entered.
// The threshold needs real margin above 0 -- a single hit can deal far more
// than a few percent of max HP, so too tight a threshold means the health
// can drop straight through the window between two polls and reach 0 before
// the monitor ever gets a chance to intervene, letting the real death happen.
//
// NOTE: A direct DeathEvents.OnEnter hook was tried and reverted -- skipping
// wrappedMethod() to prevent the vanilla death sequence left the player's
// input completely broken (no WASD, no ESC/pause menu; only jump and camera
// zoom still worked), because the FSM apparently needs that method's
// internal bookkeeping to run even when we don't want the visual death
// sequence to play. Catching low health before Death is ever entered avoids
// touching that state machine at all. Also avoids the previously-reported
// TANSTAAFL conflict.

/// Forces a defeat scene to end after a fixed duration. Guards against the
/// scene running indefinitely regardless of stage/auto-advance configuration.
public class NightSceneDefeatTimeoutCallback extends DelayCallback {
    public let sceneId: Uint64;

    public func Call() -> Void {
        let manager = NightSceneServices.Get().SceneManager();
        let scene = manager.GetActiveScene();
        // Only cancel if this is still the same scene (it may have already
        // ended naturally or been replaced by a new one).
        if IsDefined(scene) && scene.sceneId == this.sceneId {
            LogChannel(n"NightScene", "Defeat scene timeout reached, ending scene");
            manager.CancelScene();
        }
    }
}

// ============================================================
//  NPC DEFEAT DETECTION (Player defeats an NPC)
// ============================================================
// No automatic trigger here. A defeated NPC (game's own "Defeated" state --
// unconscious, not dead) only gets the scene when the player manually walks
// up and presses the interaction hotkey. See NightSceneInteractionHandler
// .OnInteractionHotkey in NPCInteraction.reds, which checks
// ScriptedPuppet.IsDefeated(npc) and calls
// NightSceneDefeatHelper.TriggerNPCDefeatScene directly.

/// Callback to unfreeze enemies after defeat grace period expires.
public class NightSceneEnemyUnfreezeCallback extends DelayCallback {
    public let playerRef: wref<PlayerPuppet>;

    public func Call() -> Void {
        if !IsDefined(this.playerRef) {
            return;
        }

        // Find all nearby NPCs and just remove their freeze -- their original hostile attitude is intact
        let npcs = NightSceneNPCFinder.FindNPCsInRange(this.playerRef, 50.0);
        let i: Int32 = 0;
        while i < ArraySize(npcs) {
            StatusEffectHelper.RemoveStatusEffect(npcs[i], t"BaseStatusEffect.intomovementLockActive");
            i += 1;
        }
        LogChannel(n"NightScene", "Grace period expired: " + IntToString(ArraySize(npcs)) + " NPCs unfrozen");
    }
}

public class NightSceneHealthCheckCallback extends DelayCallback {
    public let monitor: wref<NightSceneHealthMonitor>;

    public func Call() -> Void {
        if IsDefined(this.monitor) {
            this.monitor.OnHealthCheck();
        }
    }
}

public class NightSceneHealthMonitor extends IScriptable {
    private let m_active: Bool;
    private let m_delayId: DelayID;
    private let m_checkCount: Int32;
    private let m_startupGrace: Int32; // Skip first N checks to avoid false trigger on load
    private let m_cooldown: Int32;     // Cooldown after defeat scene (prevent re-trigger)

    public func Start() -> Void {
        this.m_active = true;
        this.m_startupGrace = 100; // Skip first 100 checks (10 seconds) after start
        this.m_checkCount = 0;
        this.ScheduleNext();
        LogChannel(n"NightScene", "Health monitor started (0.1s interval, 10s startup grace)");
    }

    public func Stop() -> Void {
        this.m_active = false;
    }

    public func OnHealthCheck() -> Void {
        if !this.m_active {
            return;
        }

        let config = NightSceneServices.Get().SceneManager().GetConfig();
        if !config.enabled || !config.defeatEnabled {
            this.ScheduleNext();
            return;
        }

        // Don't trigger if scene already active
        if NightSceneServices.Get().SceneManager().IsSceneActive() {
            this.ScheduleNext();
            return;
        }

        // Startup grace period: skip checks during save load to avoid false trigger
        if this.m_startupGrace > 0 {
            this.m_startupGrace -= 1;
            this.ScheduleNext();
            return;
        }

        // Cooldown after a defeat scene (60 checks = 30 seconds)
        if this.m_cooldown > 0 {
            this.m_cooldown -= 1;
            this.ScheduleNext();
            return;
        }

        let gi = GetGameInstance();
        let player = GetPlayer(gi) as PlayerPuppet;
        if !IsDefined(player) {
            this.ScheduleNext();
            return;
        }

        // Playing as Johnny. His death at the end of the flashback is a
        // scripted quest death -- intercept it and the sequence never resolves.
        if NightScenePlayerState.IsPlayerJohnny(player) {
            this.ScheduleNext();
            return;
        }

        // Only skip if not in combat AND health is not critical/fatal
        let trackerComp = player.GetTargetTrackerComponent();
        let inCombat = IsDefined(trackerComp) && ArraySize(trackerComp.GetHostileThreats(false)) > 0;

        let healthPct = NightSceneDefeatHelper.GetPlayerHealthPercent(player);

        if !inCombat && healthPct > config.defeatHealthThreshold {
            this.ScheduleNext();
            return;
        }

        // Debug: log every 100 checks (~10 seconds)
        this.m_checkCount += 1;
        if this.m_checkCount % 100 == 0 {
            LogChannel(n"NightScene", "Health monitor tick #" + IntToString(this.m_checkCount) + " HP=" + FloatToString(healthPct * 100.0) + "% threshold=" + FloatToString(config.defeatHealthThreshold * 100.0) + "%");
        }

        // Check if health is below or at threshold (including 0 HP instant heavy hits)
        if healthPct <= config.defeatHealthThreshold {
            LogChannel(n"NightScene", "Health monitor: threshold reached! HP=" + FloatToString(healthPct * 100.0) + "% threshold=" + FloatToString(config.defeatHealthThreshold * 100.0) + "%");

            NightSceneDefeatHelper.PreventDeath(player);

            let attacker = NightSceneNPCFinder.FindNearestHostileNPC(player, 30.0);
            if !IsDefined(attacker) {
                attacker = NightSceneNPCFinder.FindNearestNPCInFront(player, 30.0);
            }
            if !IsDefined(attacker) {
                attacker = NightSceneNPCFinder.FindNearestNPC(player, 30.0);
            }

            if IsDefined(attacker) {
                NightSceneDefeatHelper.TriggerDefeatScene(player, attacker);
                // Set cooldown from config (convert seconds to check count at 0.02s interval)
                let cooldownSec = config.defeatCooldown;
                if cooldownSec < 5.0 { cooldownSec = 5.0; } // minimum 5 seconds
                this.m_cooldown = Cast<Int32>(cooldownSec / 0.02);
            } else {
                LogChannel(n"NightScene", "Health monitor: no NPC found for defeat scene");
            }
            // Continue scheduling even after trigger (cooldown handles re-trigger prevention)
            this.ScheduleNext();
            return;
        }

        this.ScheduleNext();
    }

    private func ScheduleNext() -> Void {
        let gi = GetGameInstance();
        let delaySys = GameInstance.GetDelaySystem(gi);
        let cb = new NightSceneHealthCheckCallback();
        cb.monitor = this;
        this.m_delayId = delaySys.DelayCallback(cb, 0.02, false);
    }
}

// ============================================================
//  DEFEAT HELPER FUNCTIONS
// ============================================================

// ============================================================
//  DIRECT ENGINE DEATH HOOKS
// ============================================================
// The health poll alone misses instant kills -- a single heavy hit can take
// V from healthy to dead between two checks. These wrap the death pipeline
// itself: intercepting the death event, and suppressing the death VFX, SFX,
// state machine and menu for as long as a scene is running.

@wrapMethod(PlayerPuppet)
protected cb func OnDeath(evt: ref<gameDeathEvent>) -> Bool {
    let mgr = NightSceneServices.Get().SceneManager();
    if mgr.IsExecutingFatalDeath() {
        LogChannel(n"NightScene", "OnDeath: Executing intentional fatal death sequence");
        return wrappedMethod(evt);
    }

    // Never intercept Johnny's death. This is the one that was reported:
    // Smasher kills Johnny, the defeat scene swallows the death event, and the
    // flashback is left with nobody dead.
    if NightScenePlayerState.IsPlayerJohnny(this) {
        LogChannel(n"NightScene", "OnDeath: playing as Johnny, passing through");
        return wrappedMethod(evt);
    }

    let config = mgr.GetConfig();
    if config.enabled && config.defeatEnabled {
        if !mgr.IsSceneActive() {
            let attacker = NightSceneNPCFinder.FindNearestHostileNPC(this, 30.0);
            if !IsDefined(attacker) {
                attacker = NightSceneNPCFinder.FindNearestNPCInFront(this, 30.0);
            }
            if !IsDefined(attacker) {
                attacker = NightSceneNPCFinder.FindNearestNPC(this, 30.0);
            }

            if IsDefined(attacker) {
                LogChannel(n"NightScene", "OnDeath intercepted: triggering defeat scene before flatline");
                NightSceneDefeatHelper.PreventDeath(this);
                NightSceneDefeatHelper.TriggerDefeatScene(this, attacker);
                return false;
            }
        }
    }
    return wrappedMethod(evt);
}

@wrapMethod(PlayerPuppet)
private final func UpdateHealthStateVFX(healthValue: Float) -> Void {
    let mgr = NightSceneServices.Get().SceneManager();
    if mgr.IsSceneActive() {
        NightSceneDefeatHelper.KillAllScreenEffects(this);
        return;
    }
    wrappedMethod(healthValue);
}

@wrapMethod(PlayerPuppet)
private final func UpdateHealthStateSFX(healthValue: Float) -> Void {
    let mgr = NightSceneServices.Get().SceneManager();
    if mgr.IsSceneActive() {
        GameInstance.GetAudioSystem(this.GetGame()).NotifyGameTone(n"InNormalHealth");
        return;
    }
    wrappedMethod(healthValue);
}

@wrapMethod(DeathEvents)
protected func OnEnter(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    let mgr = NightSceneServices.Get().SceneManager();
    if mgr.IsExecutingFatalDeath() {
        wrappedMethod(stateContext, scriptInterface);
        return;
    }
    // Belt and braces: a scene should never be active while playing as Johnny,
    // but this hook is the one that can hard-block a scripted quest death.
    if NightScenePlayerState.IsPlayerJohnny(scriptInterface.executionOwner as PlayerPuppet) {
        wrappedMethod(stateContext, scriptInterface);
        return;
    }
    if mgr.IsSceneActive() {
        return;
    }
    wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(gameuiInGameMenuGameController)
protected cb func OnDeathScreenDelayEvent(evt: ref<DeathMenuDelayEvent>) -> Bool {
    let mgr = NightSceneServices.Get().SceneManager();
    // NEVER suppress if intentional fatal death is executing
    if mgr.IsExecutingFatalDeath() {
        return wrappedMethod(evt);
    }
    // ...or if the death belongs to Johnny rather than V.
    if NightScenePlayerState.IsPlayingAsJohnny(GetGameInstance()) {
        return wrappedMethod(evt);
    }
    if mgr.IsSceneActive() {
        LogChannel(n"NightScene", "Suppressing death screen delay event during active defeat scene");
        return false;
    }
    return wrappedMethod(evt);
}


public abstract class NightSceneDefeatHelper {

    /// Logs all currently applied status effects on the player puppet.
    public static func LogPlayerStatusEffects(player: ref<PlayerPuppet>, stageTag: String) -> Void {
        if !IsDefined(player) { return; }
        let ses = GameInstance.GetStatusEffectSystem(player.GetGame());
        if !IsDefined(ses) { return; }
        let appliedEffects: array<ref<StatusEffect>>;
        ses.GetAppliedEffects(player.GetEntityID(), appliedEffects);

        LogChannel(n"NightScene", "==========================================================");
        LogChannel(n"NightScene", ">>> NIGHTSCENE STATUS REPORT [" + stageTag + "] <<<");
        LogChannel(n"NightScene", "Player Entity ID: " + EntityID.ToDebugString(player.GetEntityID()));
        LogChannel(n"NightScene", "Total Active Effects: " + IntToString(ArraySize(appliedEffects)));
        let i: Int32 = 0;
        while i < ArraySize(appliedEffects) {
            let eff = appliedEffects[i];
            if IsDefined(eff) {
                let rec = eff.GetRecord();
                if IsDefined(rec) {
                    let id = rec.GetID();
                    let dur = eff.GetRemainingDuration();
                    let count = eff.GetStackCount();
                    LogChannel(n"NightScene", "  [" + IntToString(i + 1) + "] " + TDBID.ToStringDEBUG(id) + " | Dur: " + FloatToString(dur) + "s | Stacks: " + IntToString(Cast<Int32>(count)));
                }
            }
            i += 1;
        }
        LogChannel(n"NightScene", "==========================================================");
    }

    /// Dispatches an entKillEffectEvent and stops all effect instances on an entity.
    public static func KillEffect(obj: ref<GameObject>, effectName: CName) -> Void {
        if !IsDefined(obj) { return; }
        let evt = new entKillEffectEvent();
        evt.effectName = effectName;
        evt.breakAllLoops = true;
        obj.QueueEvent(evt);
        GameObjectEffectHelper.BreakEffectLoopEvent(obj, effectName);
        GameObjectEffectHelper.StopEffectEvent(obj, effectName);
    }

    /// Extinguishes all full-screen post-processing overlays, death shaders, and elemental vignettes.
    public static func KillAllScreenEffects(player: ref<PlayerPuppet>) -> Void {
        if !IsDefined(player) { return; }
        NightSceneDefeatHelper.KillEffect(player, n"fx_health_critical");
        NightSceneDefeatHelper.KillEffect(player, n"fx_health_low");
        NightSceneDefeatHelper.KillEffect(player, n"eyes_closing_instant");
        NightSceneDefeatHelper.KillEffect(player, n"eyes_closed_loop");
        NightSceneDefeatHelper.KillEffect(player, n"transition_glitch_loop");
        NightSceneDefeatHelper.KillEffect(player, n"dying");
        NightSceneDefeatHelper.KillEffect(player, n"death");
        NightSceneDefeatHelper.KillEffect(player, n"low_health");
        NightSceneDefeatHelper.KillEffect(player, n"critical_health");
        NightSceneDefeatHelper.KillEffect(player, n"damage_screen");
        NightSceneDefeatHelper.KillEffect(player, n"damage_screen_critical");
        NightSceneDefeatHelper.KillEffect(player, n"blackout");
        NightSceneDefeatHelper.KillEffect(player, n"fade_in");
        NightSceneDefeatHelper.KillEffect(player, n"fade_out");
        NightSceneDefeatHelper.KillEffect(player, n"hud_blackout");
        NightSceneDefeatHelper.KillEffect(player, n"player_death_vignette");
        NightSceneDefeatHelper.KillEffect(player, n"status_bleeding");
        NightSceneDefeatHelper.KillEffect(player, n"status_poisoned");
        NightSceneDefeatHelper.KillEffect(player, n"status_burning");
        NightSceneDefeatHelper.KillEffect(player, n"status_electrocuted");
        NightSceneDefeatHelper.KillEffect(player, n"status_emp");
        NightSceneDefeatHelper.KillEffect(player, n"status_blinded");
        NightSceneDefeatHelper.KillEffect(player, n"status_deafened");
        NightSceneDefeatHelper.KillEffect(player, n"status_stunned");
        NightSceneDefeatHelper.KillEffect(player, n"stealth_mode");
        NightSceneDefeatHelper.KillEffect(player, n"fish_eye");
        NightSceneDefeatHelper.KillEffect(player, n"camera_mask");
    }

    /// Strips all stacks of a specific status effect from the player.
    /// Remove a status effect, trying every removal form.
    ///
    /// The game can accept the plain two-argument RemoveStatusEffect without
    /// actually removing an INSTIGATOR-OWNED effect -- it reports success and
    /// the effect stays on. That is why a defeat scene could leave V stuck
    /// invulnerable or unable to move even though the mod "removed" it. So all
    /// three forms are tried, and the result is verified rather than assumed.
    ///
    /// Anything that survives is logged, so a stuck player leaves evidence
    /// instead of a silent failure.
    public static func StripStatusEffectAllStacks(player: ref<PlayerPuppet>, id: TweakDBID) -> Void {
        if !IsDefined(player) { return; }
        let ses = GameInstance.GetStatusEffectSystem(player.GetGame());
        if !IsDefined(ses) { return; }

        let eid = player.GetEntityID();
        ses.RemoveStatusEffect(eid, id);
        ses.RemoveStatusEffect(eid, id, 99u);
        StatusEffectHelper.RemoveStatusEffect(player, id);

        if ses.HasStatusEffect(eid, id) {
            LogChannel(n"NightScene", "Status effect survived removal: " + TDBID.ToStringDEBUG(id));
        }
    }

    /// Completely strips all movement/combat locks, menu blockers, low-health glitch overlays, and invulnerability.
    public static func RemoveAllGameplayRestrictions(player: ref<PlayerPuppet>) -> Void {
        if !IsDefined(player) { return; }
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.NoMovement");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.NoJump");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.NoCrouch");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.NoCombat");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.NoShooting");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.NoWeapons");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.FastForwardLockMovement");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.BlockAllMenu");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"GameplayRestriction.PreventLowHealthOverlay");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.Invulnerable");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.PlayerImmortal");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"Effectors.LowHealthTBH");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"Effectors.CriticalHealthTBH");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.LowHealth");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.CriticallyLowHealth");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.JohnnySickness");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.Dying");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.DamageScreen");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.DamageIndicator");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.NetwatcherGlitch");

        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Invulnerable");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Immortal");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Debuff");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"LowHealth");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Blind");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Glitch");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"DoT");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"PreventLowHealthOverlay");
    }

    public static func GetPlayerHealthPercent(player: ref<PlayerPuppet>) -> Float {
        let gi = player.GetGame();
        let poolSys = GameInstance.GetStatPoolsSystem(gi);
        let healthPct = poolSys.GetStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, false);
        return healthPct / 100.0; // StatPool returns 0-100, normalize to 0.0-1.0
    }

    /// Prevent death AND immediately stop ALL combat.
    /// Makes player invisible/untargetable, freezes ALL hostiles, restores health to 100%.
    public static func PreventDeath(player: ref<PlayerPuppet>) -> Void {
        let gi = player.GetGame();
        let poolSys = GameInstance.GetStatPoolsSystem(gi);

        NightSceneDefeatHelper.LogPlayerStatusEffects(player, "PREVENT_DEATH: BEFORE INTERVENTION");

        // 1. Restore health to 100% & apply invulnerability + prevent low health overlay immediately
        poolSys.RequestSettingStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, 100.0, player);
        StatusEffectHelper.ApplyStatusEffect(player, t"BaseStatusEffect.Invulnerable");
        StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.PreventLowHealthOverlay");

        // Strip all obscuring overlays, third-party low health effects, and debuffs
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"Effectors.LowHealthTBH");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"Effectors.CriticalHealthTBH");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.LowHealth");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.CriticallyLowHealth");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.JohnnySickness");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.Dying");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.DamageScreen");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.DamageIndicator");
        NightSceneDefeatHelper.StripStatusEffectAllStacks(player, t"BaseStatusEffect.NetwatcherGlitch");

        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Debuff");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"LowHealth");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Blind");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"Glitch");
        StatusEffectHelper.RemoveStatusEffectsWithTag(player, n"DoT");

        // Kill all death, dying, damage, and blackout post-processing screen shaders & loops
        NightSceneDefeatHelper.KillAllScreenEffects(player);

        // Unset time dilation so world rendering and lighting tick normally
        GameInstance.GetTimeSystem(gi).UnsetTimeDilation(n"");
        GameInstance.GetTimeSystem(gi).UnsetTimeDilationOnLocalPlayerZero(n"");

        // Reset PhotoMode health state and Audio tone
        let photoBB = GameInstance.GetBlackboardSystem(gi).Get(GetAllBlackboardDefs().PhotoMode);
        if IsDefined(photoBB) {
            photoBB.SetUint(GetAllBlackboardDefs().PhotoMode.PlayerHealthState, 0u);
        }
        let audioSys = GameInstance.GetAudioSystem(gi);
        if IsDefined(audioSys) {
            audioSys.NotifyGameTone(n"Default");
        }

        // Reset player state machine blackboard so it's not trapped in Death/Combat blackout
        let psmBB = player.GetPlayerStateMachineBlackboard();
        if IsDefined(psmBB) {
            psmBB.SetInt(GetAllBlackboardDefs().PlayerStateMachine.HighLevel, EnumInt(gamePSMHighLevel.Default), true);
            psmBB.SetInt(GetAllBlackboardDefs().PlayerStateMachine.Combat, EnumInt(gamePSMCombat.OutOfCombat), true);
            psmBB.SetInt(GetAllBlackboardDefs().PlayerStateMachine.Vision, EnumInt(gamePSMVision.Default), true);
            psmBB.SetInt(GetAllBlackboardDefs().PlayerStateMachine.Vitals, EnumInt(gamePSMVitals.Alive), true);
            psmBB.SetBool(GetAllBlackboardDefs().PlayerStateMachine.DisplayDeathMenu, false, true);
        }

        // 2. Make player invisible (enemies can't see V)
        player.SetInvisible(true);

        // 3. Remove player from ALL hostile threat lists AND freeze ALL hostiles
        let trackerComp = player.GetTargetTrackerComponent();
        if IsDefined(trackerComp) {
            let threats = trackerComp.GetHostileThreats(false);
            let playerAgent = player.GetAttitudeAgent();
            let i: Int32 = 0;
            while i < ArraySize(threats) {
                let hostileEntity = threats[i].entity as ScriptedPuppet;
                if IsDefined(hostileEntity) {
                    // Remove player from this NPC's threat list
                    let hostileTracker = hostileEntity.GetTargetTrackerComponent();
                    if IsDefined(hostileTracker) {
                        hostileTracker.DeactivateThreat(player);
                    }

                    // Freeze this NPC (stop all movement/combat AI)
                    StatusEffectHelper.ApplyStatusEffect(hostileEntity, t"GameplayRestriction.NoMovement");

                    // DON'T change attitude -- keep them hostile so they re-aggro when unfrozen
                    // Just deactivating threat + freeze is enough to stop combat
                }
                i += 1;
            }
            LogChannel(n"NightScene", "Froze " + IntToString(ArraySize(threats)) + " hostile NPCs");
        }

        NightSceneDefeatHelper.LogPlayerStatusEffects(player, "PREVENT_DEATH: AFTER INTERVENTION");

        LogChannel(n"NightScene", "Combat stopped: player invisible, HP=100%, all hostiles frozen");
    }

    /// Schedule enemy unfreeze after defeat scene ends, OR flatline player if defeatFatalMode is enabled.
    /// Player visibility is handled by RestorePlayerFromScene (called separately).
    public static func RestoreFromDefeat(player: ref<PlayerPuppet>) -> Void {
        let config = NightSceneServices.Get().SceneManager().GetConfig();
        if config.defeatFatalMode {
            NightSceneServices.Get().SceneManager().SetExecutingFatalDeath(true);

            NightSceneDefeatHelper.LogPlayerStatusEffects(player, "RESTORE_FROM_DEFEAT: FATAL MODE START");

            let gi = player.GetGame();

            // Clear any GodMode or Immortality registrations
            let godMode = GameInstance.GetGodModeSystem(gi);
            if IsDefined(godMode) {
                godMode.ClearGodMode(player.GetEntityID(), n"Default");
                godMode.ClearGodMode(player.GetEntityID(), n"NightScene");
                godMode.RemoveGodMode(player.GetEntityID(), gameGodModeType.Invulnerable, n"Default");
                godMode.RemoveGodMode(player.GetEntityID(), gameGodModeType.Immortal, n"Default");
            }

            // Strip ALL restrictions, invulnerabilities, and menu blockers completely
            NightSceneDefeatHelper.RemoveAllGameplayRestrictions(player);
            player.SetInvisible(false);

            // Set health pool to 0.0
            let poolSys = GameInstance.GetStatPoolsSystem(gi);
            poolSys.RequestSettingStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, 0.0, null, true);

            // Trigger fatal kill sequence
            StatusEffectHelper.ApplyStatusEffect(player, t"BaseStatusEffect.ForceKill");
            player.Kill(null, false, false);
            player.QueueEvent(new gameDeathEvent());

            // Reset and trigger PSM DisplayDeathMenu
            let psmBB = player.GetPlayerStateMachineBlackboard();
            if IsDefined(psmBB) {
                psmBB.SetInt(GetAllBlackboardDefs().PlayerStateMachine.Vitals, EnumInt(gamePSMVitals.Dead), true);
                psmBB.SetBool(GetAllBlackboardDefs().PlayerStateMachine.DisplayDeathMenu, false, true);
                psmBB.SetBool(GetAllBlackboardDefs().PlayerStateMachine.DisplayDeathMenu, true, true);
            }

            // Direct UI event dispatch to switch scenario to MenuScenario_DeathMenu
            let uiSys = GameInstance.GetUISystem(gi);
            if IsDefined(uiSys) {
                let menuEvent = new inkMenuInstance_SpawnEvent();
                menuEvent.Init(n"OnShowDeathMenu");
                uiSys.QueueEvent(menuEvent);
            }

            NightSceneDefeatHelper.LogPlayerStatusEffects(player, "RESTORE_FROM_DEFEAT: FATAL MODE AFTER KILL");

            LogChannel(n"NightScene", "Fatal defeat mode active: player killed on scene conclusion");
            return;
        }

        // Undo everything PreventDeath applied. This is NOT optional: it
        // applies BaseStatusEffect.Invulnerable to stop V dying mid-scene, and
        // until this call existed only the fatal-mode branch below removed it.
        // Every ordinary defeat scene therefore left V permanently invulnerable
        // with no way back short of reloading a save -- the single most
        // reported bug in the defeat system.
        NightSceneDefeatHelper.RemoveAllGameplayRestrictions(player);
        NightSceneDefeatHelper.LogPlayerStatusEffects(player, "RESTORE_FROM_DEFEAT: AFTER CLEANUP");

        // Schedule enemy unfreeze after grace period
        let gracePeriod = config.defeatGracePeriod;
        if gracePeriod <= 0.0 {
            gracePeriod = 0.1; // minimum delay
        }

        let gi = player.GetGame();
        let delaySys = GameInstance.GetDelaySystem(gi);
        let cb = new NightSceneEnemyUnfreezeCallback();
        cb.playerRef = player;
        delaySys.DelayCallback(cb, gracePeriod, false);

        LogChannel(n"NightScene", "Player restored. Enemies unfreeze in " + FloatToString(gracePeriod) + "s");
    }

    /// Deduct money from player on defeat.
    public static func DeductMoneyOnDefeat(player: ref<PlayerPuppet>) -> Void {
        let config = NightSceneServices.Get().SceneManager().GetConfig();
        LogChannel(n"NightScene", "DeductMoney: config.defeatMoneyLoss=" + FloatToString(config.defeatMoneyLoss) + " isPercent=" + BoolToString(config.defeatMoneyLossIsPercent));
        if config.defeatMoneyLoss <= 0.0 {
            LogChannel(n"NightScene", "DeductMoney: disabled (loss=0)");
            return;
        }

        let gi = player.GetGame();
        let ts = GameInstance.GetTransactionSystem(gi);
        let currentMoney = ts.GetItemQuantity(player, MarketSystem.Money());
        let loss: Int32;

        if config.defeatMoneyLossIsPercent {
            loss = Cast<Int32>(Cast<Float>(currentMoney) * config.defeatMoneyLoss / 100.0);
        } else {
            loss = Cast<Int32>(config.defeatMoneyLoss);
        }

        if loss > 0 && loss <= currentMoney {
            ts.RemoveItem(player, MarketSystem.Money(), loss);
            LogChannel(n"NightScene", "Defeat money loss: " + IntToString(loss) + " eddies");
        }
    }

    /// Order two actors into a scene's actor array.
    ///
    /// GENDER/RIG LOCKING DISABLED (commented out below) per user request: any
    /// gender may now use any animation, regardless of which body the clip in
    /// each slot was originally authored for. Users can exclude specific
    /// animations they don't want via the anim browser's enable/disable toggle
    /// instead. To restore the old behavior (female always forced into slot 0
    /// for mixed-gender pairings), uncomment the block below and remove the
    /// unconditional block that follows it.
    public static func OrderActorsForScene(
        player: ref<GameObject>,
        npc: ref<GameObject>,
        playerIsFemale: Bool,
        npcIsFemale: Bool,
        desiredPosition: NightScenePlayerPosition
    ) -> array<ref<GameObject>> {
        let actors: array<ref<GameObject>>;

        // if !(playerIsFemale && npcIsFemale) {
        //     // Mixed-gender/big pairing: gender/rig-locked, ignore desiredPosition
        //     if npcIsFemale && !playerIsFemale {
        //         ArrayPush(actors, npc);
        //         ArrayPush(actors, player);
        //     } else {
        //         ArrayPush(actors, player);
        //         ArrayPush(actors, npc);
        //     }
        //     return actors;
        // }

        // Always honor the player's position preference, regardless of gender.
        // amm_loader.lua now registers every branch (mf/mbf/ff) with the "_a"
        // clip in slot 0 and "_b" in slot 1, so slot 0 is consistently the
        // active/Dom role and this mapping is a straight one.
        if Equals(EnumInt(desiredPosition), EnumInt(NightScenePlayerPosition.PositionTwo)) {
            ArrayPush(actors, npc);
            ArrayPush(actors, player);
        } else {
            ArrayPush(actors, player);
            ArrayPush(actors, npc);
        }
        return actors;
    }

    public static func TriggerDefeatScene(player: ref<PlayerPuppet>, attacker: ref<ScriptedPuppet>) -> Void {
        // All hostiles already frozen by PreventDeath (called before this)

        // Deduct money immediately on defeat trigger
        NightSceneDefeatHelper.DeductMoneyOnDefeat(player);

        let registry = NightSceneServices.Get().AnimRegistry();
        let manager = NightSceneServices.Get().SceneManager();
        let actorCtrl = NightSceneServices.Get().ActorController();

        let playerGender = actorCtrl.DetectGender(player);
        let attackerGender = actorCtrl.DetectGender(attacker);

        let playerIsFemale = Equals(EnumInt(playerGender), EnumInt(NightSceneGender.Female));
        let attackerIsFemale = Equals(EnumInt(attackerGender), EnumInt(NightSceneGender.Female));

        // GENDER-BASED TAG SELECTION DISABLED per user request: any gender may
        // use any animation now. Users can exclude specific animations via the
        // anim browser toggle instead. To restore gender-matched selection,
        // uncomment this block and remove the unconditional "paired" query below.
        // let eitherIsBig = Equals(EnumInt(playerGender), EnumInt(NightSceneGender.MaleBig)) || Equals(EnumInt(attackerGender), EnumInt(NightSceneGender.MaleBig));
        // let tags: array<String>;
        // if playerIsFemale && attackerIsFemale {
        //     ArrayPush(tags, "ff");
        // } else {
        //     if eitherIsBig {
        //         ArrayPush(tags, "mbf");
        //     } else {
        //         ArrayPush(tags, "mf");
        //     }
        // }
        // let emptyGenders: array<NightSceneGender>;
        // let animDef = registry.GetRandom(tags, 2, emptyGenders, false);
        // if !IsDefined(animDef) {
        //     let fallbackTags: array<String>;
        //     ArrayPush(fallbackTags, "paired");
        //     animDef = registry.GetRandom(fallbackTags, 2, emptyGenders, false);
        // }

        let emptyGenders: array<NightSceneGender>;
        let pairedTags: array<String>;
        ArrayPush(pairedTags, "paired");
        let animDef = registry.GetRandom(pairedTags, 2, emptyGenders, false);

        if !IsDefined(animDef) {
            LogChannel(n"NightScene", "No matching animation found for defeat scene");
            // PreventDeath already made the player invisible/camo-blocked and froze
            // hostiles -- undo that now, since no scene will start to clean it up later.
            NightSceneAPI.RestorePlayerFromScene();
            return;
        }

        // Player is the one being defeated -- always Position Two.
        let actors = NightSceneDefeatHelper.OrderActorsForScene(player, attacker, playerIsFemale, attackerIsFemale, NightScenePlayerPosition.PositionTwo);

        let scenePos = player.GetWorldPosition();
        let started = manager.StartScene(animDef, actors, NightSceneTriggerSource.Defeat, scenePos);

        if started {
            // Signal Lua side to spawn workspot
            NightSceneAPI.SetPendingWorkspotSpawn(true);
            LogChannel(n"NightScene", "Defeat scene started, signaling Lua spawner");

            // Force the scene to end after a fixed duration -- don't rely on the
            // generic stage auto-advance timer, since this scene must not run forever.
            let scene = manager.GetActiveScene();
            if IsDefined(scene) {
                let delaySys = GameInstance.GetDelaySystem(player.GetGame());
                let timeoutCb = new NightSceneDefeatTimeoutCallback();
                timeoutCb.sceneId = scene.sceneId;
                delaySys.DelayCallback(timeoutCb, 30.0, false);
            }
        } else {
            // Scene failed to start -- undo PreventDeath's effects so the player
            // isn't left invisible/camo-blocked with hostiles frozen forever.
            LogChannel(n"NightScene", "Defeat scene failed to start");
            NightSceneAPI.RestorePlayerFromScene();
        }
    }

    public static func TriggerNPCDefeatScene(player: ref<PlayerPuppet>, defeatedNPC: ref<ScriptedPuppet>) -> Void {
        let registry = NightSceneServices.Get().AnimRegistry();
        let manager = NightSceneServices.Get().SceneManager();
        let actorCtrl = NightSceneServices.Get().ActorController();

        let playerGender = actorCtrl.DetectGender(player);
        let npcGender = actorCtrl.DetectGender(defeatedNPC);

        let playerIsFemale = Equals(EnumInt(playerGender), EnumInt(NightSceneGender.Female));
        let npcIsFemale = Equals(EnumInt(npcGender), EnumInt(NightSceneGender.Female));

        // GENDER-BASED TAG SELECTION DISABLED per user request: any gender may
        // use any animation now. Users can exclude specific animations via the
        // anim browser toggle instead. To restore gender-matched selection,
        // uncomment this block and remove the unconditional "paired" query below.
        // let eitherIsBig = Equals(EnumInt(playerGender), EnumInt(NightSceneGender.MaleBig)) || Equals(EnumInt(npcGender), EnumInt(NightSceneGender.MaleBig));
        // let tags: array<String>;
        // if playerIsFemale && npcIsFemale {
        //     ArrayPush(tags, "ff");
        // } else {
        //     if eitherIsBig {
        //         ArrayPush(tags, "mbf");
        //     } else {
        //         ArrayPush(tags, "mf");
        //     }
        // }
        // let emptyGenders: array<NightSceneGender>;
        // let animDef = registry.GetRandom(tags, 2, emptyGenders, false);

        let emptyGenders: array<NightSceneGender>;
        let pairedTags: array<String>;
        ArrayPush(pairedTags, "paired");
        let animDef = registry.GetRandom(pairedTags, 2, emptyGenders, false);

        if !IsDefined(animDef) {
            LogChannel(n"NightScene", "No matching animation for NPC defeat scene");
            return;
        }

        // Player is the one defeating -- honor the general position preference.
        let desiredPosition = NightSceneServices.Get().SceneManager().GetConfig().playerPosition;
        let actors = NightSceneDefeatHelper.OrderActorsForScene(player, defeatedNPC, playerIsFemale, npcIsFemale, desiredPosition);

        let scenePos = defeatedNPC.GetWorldPosition();
        let started = manager.StartScene(animDef, actors, NightSceneTriggerSource.NPCDefeat, scenePos);

        if started {
            NightSceneAPI.SetPendingWorkspotSpawn(true);
        }
    }
}
