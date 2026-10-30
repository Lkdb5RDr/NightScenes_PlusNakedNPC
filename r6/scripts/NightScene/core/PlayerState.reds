// NightScene Framework - Player State
// =====================================
// Checks on who the player currently *is*, as opposed to what they are doing.
//
// The framework assumes the player-controlled puppet is V. During the playable
// Johnny sequences that assumption breaks, and acting on it breaks the quest:
// Johnny's death at Smasher's hands is a scripted quest death, so intercepting
// it with a defeat scene leaves the sequence hanging -- the scene plays out and
// then nobody dies.

/// Johnny-control checks, used to gate the whole framework.
public abstract class NightScenePlayerState {

    /// True while the player is playing as Johnny rather than V.
    ///
    /// Two distinct engine states, both of which have to suppress us:
    ///   * Replacer -- the playable flashbacks (Never Fade Away, the 2023
    ///     Arasaka raid) swap the local player puppet out for a Johnny puppet.
    ///   * Possession -- the segments where Johnny takes over V's body. Same
    ///     puppet, so this one is only visible as a quest fact.
    public static func IsPlayingAsJohnny(gi: GameInstance) -> Bool {
        let playerSystem = GameInstance.GetPlayerSystem(gi);
        if !IsDefined(playerSystem) {
            return false;
        }

        // The controlled object is the one the defeat hooks actually fire on;
        // the main object is what most mods check. They can disagree during the
        // hand-off frames, so test both.
        let controlled = playerSystem.GetLocalPlayerControlledGameObject() as PlayerPuppet;
        if IsDefined(controlled) && controlled.IsJohnnyReplacer() {
            return true;
        }

        let main = playerSystem.GetLocalPlayerMainGameObject() as PlayerPuppet;
        if IsDefined(main) && main.IsJohnnyReplacer() {
            return true;
        }

        let factName: String = playerSystem.GetPossessedByJohnnyFactName();
        if NotEquals(factName, "") {
            return GameInstance.GetQuestsSystem(gi).GetFactStr(factName) == 1;
        }

        return false;
    }

    /// Same check, starting from a puppet the caller already has.
    ///
    /// Preferred inside the death hooks: `this` is the puppet that is actually
    /// dying, so its own replacer flag is more reliable than asking the player
    /// system which puppet it considers current.
    public static func IsPlayerJohnny(player: ref<PlayerPuppet>) -> Bool {
        if IsDefined(player) && player.IsJohnnyReplacer() {
            return true;
        }
        if IsDefined(player) {
            return NightScenePlayerState.IsPlayingAsJohnny(player.GetGame());
        }
        return NightScenePlayerState.IsPlayingAsJohnny(GetGameInstance());
    }
}
