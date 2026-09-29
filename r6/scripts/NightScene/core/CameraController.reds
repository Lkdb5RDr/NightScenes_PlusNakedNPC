// NightScene Framework - Camera Controller
// ===========================================
// Manages camera vantage points and spectator views during scenes:
//   - Scene-Relative Trigonometric Angles (projected directly from workspot center)
//   - 100% Invisible Spectator Camera (no player mesh visible)
//   - Unclamped First-Person head bone look-around (360 degree panoramic view)
//   - Third-Person mode with scene as focal point
//   - Static Cinematic Presets (Front, Rear, Left, Right, Overhead)
//   - Free Cam wide perspective
//   - Dedicated Cycle (First -> Third -> Free) and Next Angle (Enters Cinematic -> Cycles presets)

/// Stored camera state for restoration after a scene.
public class NightSceneSavedCameraState extends IScriptable {
    public let playerPosition: Vector4;
    public let playerRotation: EulerAngles;
    public let wasFirstPerson: Bool;
    public let fov: Float;
    public let pitchMax: Float;
    public let pitchMin: Float;
    public let yawMaxLeft: Float;
    public let yawMaxRight: Float;
}

/// Cinematic camera preset definition relative to scene center.
public class NightSceneCameraPreset extends IScriptable {
    public let name: String;
    public let distance: Float;       // Radial distance from scene center
    public let heightOffset: Float;   // Height offset above scene
    public let angleOffsetDeg: Float; // Angle offset relative to scene yaw
    public let pitchAngle: Float;     // Camera vertical tilt
    public let fov: Float;            // Field of view
}

/// Singleton camera controller for NightScene.
public class NightSceneCameraController extends IScriptable {

    // Saved pre-scene camera state
    private let m_savedState: ref<NightSceneSavedCameraState>;

    // Whether we've overridden the camera
    private let m_isOverriding: Bool;

    // Current camera mode
    private let m_currentMode: NightSceneCameraMode;

    // Available cinematic presets
    private let m_presets: array<ref<NightSceneCameraPreset>>;

    // Current cinematic preset index
    private let m_currentPresetIndex: Int32;

    // Active scene reference for live preset updates
    private let m_activeScene: wref<NightSceneInstance>;

    /// Set up default cinematic camera presets relative to scene center.
    public func InitializePresets() -> Void {
        this.m_isOverriding = false;
        this.m_currentPresetIndex = 0;
        ArrayClear(this.m_presets);

        // Preset 0: Front View (facing lovers directly)
        let front = new NightSceneCameraPreset();
        front.name = "Front View";
        front.distance = 2.0;
        front.heightOffset = 0.4;
        front.angleOffsetDeg = 180.0;
        front.pitchAngle = -6.0;
        front.fov = 62.0;
        ArrayPush(this.m_presets, front);

        // Preset 1: Rear View (over-the-shoulder from behind)
        let rear = new NightSceneCameraPreset();
        rear.name = "Rear View";
        rear.distance = 1.8;
        rear.heightOffset = 0.4;
        rear.angleOffsetDeg = 0.0;
        rear.pitchAngle = -6.0;
        rear.fov = 60.0;
        ArrayPush(this.m_presets, rear);

        // Preset 2: Left Side Profile
        let leftSide = new NightSceneCameraPreset();
        leftSide.name = "Left Side";
        leftSide.distance = 1.8;
        leftSide.heightOffset = 0.35;
        leftSide.angleOffsetDeg = 90.0;
        leftSide.pitchAngle = -5.0;
        leftSide.fov = 55.0;
        ArrayPush(this.m_presets, leftSide);

        // Preset 3: Right Side Profile
        let rightSide = new NightSceneCameraPreset();
        rightSide.name = "Right Side";
        rightSide.distance = 1.8;
        rightSide.heightOffset = 0.35;
        rightSide.angleOffsetDeg = -90.0;
        rightSide.pitchAngle = -5.0;
        rightSide.fov = 55.0;
        ArrayPush(this.m_presets, rightSide);

        // Preset 4: High Overhead Angle
        let topdown = new NightSceneCameraPreset();
        topdown.name = "High Angle";
        topdown.distance = 2.2;
        topdown.heightOffset = 1.4;
        topdown.angleOffsetDeg = 0.0;
        topdown.pitchAngle = -30.0;
        topdown.fov = 68.0;
        ArrayPush(this.m_presets, topdown);

        // Preset 5: Low Ground Sensual Angle
        let lowGround = new NightSceneCameraPreset();
        lowGround.name = "Low Ground";
        lowGround.distance = 1.3;
        lowGround.heightOffset = -0.35;
        lowGround.angleOffsetDeg = 30.0;
        lowGround.pitchAngle = 10.0;
        lowGround.fov = 55.0;
        ArrayPush(this.m_presets, lowGround);

        LogChannel(n"NightScene", "Camera presets initialized: " + IntToString(ArraySize(this.m_presets)));
    }

    // -------------------------------------------------------
    //  CAMERA APPLICATION
    // -------------------------------------------------------

    /// Apply the appropriate camera for the current scene state.
    public func ApplySceneCamera(scene: ref<NightSceneInstance>) -> Void {
        if !IsDefined(scene) {
            return;
        }

        this.m_activeScene = scene;
        let gi = GetGameInstance();
        let player = GetPlayer(gi);
        if !IsDefined(player) {
            return;
        }

        // Save pre-scene camera and player transform if not already saved
        if !this.m_isOverriding {
            this.SaveCameraState(player);
            this.m_isOverriding = true;
        }

        this.m_currentMode = scene.cameraMode;
        LogChannel(n"NightScene", "Scene camera mode set to: " + IntToString(EnumInt(scene.cameraMode)));
    }

    public func GetPresetIndex() -> Int32 {
        return this.m_currentPresetIndex;
    }

    public func SetPresetIndex(index: Int32) -> Void {
        if ArraySize(this.m_presets) == 0 {
            this.InitializePresets();
        }
        if ArraySize(this.m_presets) > 0 {
            let num = ArraySize(this.m_presets);
            this.m_currentPresetIndex = ((index % num) + num) % num;
        }
    }

    /// Save the current camera state before overriding.
    private func SaveCameraState(player: ref<PlayerPuppet>) -> Void {
        this.m_savedState = new NightSceneSavedCameraState();
        this.m_savedState.playerPosition = player.GetWorldPosition();
        this.m_savedState.playerRotation = player.GetWorldOrientation().ToEulerAngles();

        let fppCam = player.GetFPPCameraComponent();
        if IsDefined(fppCam) {
            this.m_savedState.fov = fppCam.GetFOV();
            this.m_savedState.pitchMax = fppCam.pitchMax;
            this.m_savedState.pitchMin = fppCam.pitchMin;
            this.m_savedState.yawMaxLeft = fppCam.yawMaxLeft;
            this.m_savedState.yawMaxRight = fppCam.yawMaxRight;
            this.m_savedState.wasFirstPerson = true;
        } else {
            this.m_savedState.fov = 70.0;
            this.m_savedState.pitchMax = 80.0;
            this.m_savedState.pitchMin = -80.0;
            this.m_savedState.yawMaxLeft = 180.0;
            this.m_savedState.yawMaxRight = -180.0;
            this.m_savedState.wasFirstPerson = true;
        }

        LogChannel(n"NightScene", "Saved camera & player state");
    }

    // -------------------------------------------------------
    //  CYCLE & PRESET TRIGGERS
    // -------------------------------------------------------

    /// Cycle between FirstPerson -> ThirdPerson -> Free -> FirstPerson (never enters Cinematic).
    public func CycleInteractiveCamera() -> Void {
        let mgr = NightSceneServices.Get().SceneManager();
        let scene = mgr.GetActiveScene();
        if !IsDefined(scene) {
            return;
        }

        let currentMode = scene.cameraMode;
        let nextMode: NightSceneCameraMode;

        if Equals(EnumInt(currentMode), EnumInt(NightSceneCameraMode.FirstPerson)) {
            nextMode = NightSceneCameraMode.ThirdPerson;
        } else if Equals(EnumInt(currentMode), EnumInt(NightSceneCameraMode.ThirdPerson)) {
            nextMode = NightSceneCameraMode.Free;
        } else {
            nextMode = NightSceneCameraMode.FirstPerson;
        }

        scene.cameraMode = nextMode;
        this.ApplySceneCamera(scene);
        LogChannel(n"NightScene", "Interactive camera cycled to: " + IntToString(EnumInt(nextMode)));
    }

    /// Trigger Next Camera Angle:
    /// - If in another mode: immediately switches to Cinematic mode.
    /// - If already in Cinematic mode: steps to the next static preset.
    public func TriggerNextCameraAngle() -> Void {
        let mgr = NightSceneServices.Get().SceneManager();
        let scene = mgr.GetActiveScene();
        if !IsDefined(scene) {
            return;
        }

        if ArraySize(this.m_presets) == 0 {
            this.InitializePresets();
        }

        let currentMode = scene.cameraMode;
        if !Equals(EnumInt(currentMode), EnumInt(NightSceneCameraMode.Cinematic)) {
            // Switch to Cinematic mode immediately
            scene.cameraMode = NightSceneCameraMode.Cinematic;
            LogChannel(n"NightScene", "Switched to Cinematic mode on preset: " + this.m_presets[this.m_currentPresetIndex].name);
        } else {
            // Already in Cinematic: step to next preset
            this.m_currentPresetIndex = (this.m_currentPresetIndex + 1) % ArraySize(this.m_presets);
            LogChannel(n"NightScene", "Cinematic preset cycled to: " + this.m_presets[this.m_currentPresetIndex].name);
        }

        this.ApplySceneCamera(scene);
    }

    /// Cycle to the previous cinematic preset.
    public func PreviousPreset() -> Void {
        if ArraySize(this.m_presets) == 0 {
            return;
        }
        this.m_currentPresetIndex -= 1;
        if this.m_currentPresetIndex < 0 {
            this.m_currentPresetIndex = ArraySize(this.m_presets) - 1;
        }
        LogChannel(n"NightScene", "Camera preset switched to: " + this.m_presets[this.m_currentPresetIndex].name);

        if IsDefined(this.m_activeScene) {
            this.ApplySceneCamera(this.m_activeScene);
        }
    }

    /// Add a custom camera preset (for mod extensibility).
    public func AddPreset(preset: ref<NightSceneCameraPreset>) -> Void {
        ArrayPush(this.m_presets, preset);
    }

    /// Get all available preset names (for UI display).
    public func GetPresetNames() -> array<String> {
        let names: array<String>;
        let i: Int32 = 0;
        while i < ArraySize(this.m_presets) {
            ArrayPush(names, this.m_presets[i].name);
            i += 1;
        }
        return names;
    }

    // -------------------------------------------------------
    //  RESTORATION
    // -------------------------------------------------------

    /// Restore the camera to its pre-scene state.
    public func RestoreCamera() -> Void {
        if !this.m_isOverriding {
            return;
        }

        let gi = GetGameInstance();
        let player = GetPlayer(gi) as PlayerPuppet;

        if IsDefined(player) {
            let fppCam = player.GetFPPCameraComponent();
            if IsDefined(fppCam) {
                fppCam.SetLocalPosition(new Vector4(0.0, 0.0, 0.0, 1.0));
                fppCam.SetLocalOrientation(new Quaternion(0.0, 0.0, 0.0, 1.0));

                if IsDefined(this.m_savedState) {
                    fppCam.SetFOV(this.m_savedState.fov);
                    fppCam.pitchMax = this.m_savedState.pitchMax;
                    fppCam.pitchMin = this.m_savedState.pitchMin;
                    fppCam.yawMaxLeft = this.m_savedState.yawMaxLeft;
                    fppCam.yawMaxRight = this.m_savedState.yawMaxRight;

                    // Restore player world position
                    GameInstance.GetTeleportationFacility(gi).Teleport(player, this.m_savedState.playerPosition, this.m_savedState.playerRotation);
                } else {
                    fppCam.SetFOV(70.0);
                    fppCam.pitchMax = 80.0;
                    fppCam.pitchMin = -80.0;
                    fppCam.yawMaxLeft = 180.0;
                    fppCam.yawMaxRight = -180.0;
                }
                fppCam.Activate(0.5);
            }
        }

        this.m_isOverriding = false;
        this.m_savedState = null;
        this.m_activeScene = null;
        LogChannel(n"NightScene", "Camera and player restored to normal gameplay state");
    }
}
