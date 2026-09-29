-- NightScene Framework - Unified AMM Camera System
-- ========================================================
-- Uses a dedicated simple_free_camera.ent entity for ALL camera modes:
--   Mode 0 (FirstPerson): 100% 3D head bone tracking + dynamic eye positioning + mouse look
--   Mode 1 (ThirdPerson): 360° spherical orbit around lovers with mouse orbit & zoom
--   Mode 2 (Cinematic): Oriented directly to V clone & partners with locked inputs
--   Mode 3 (FreeCam): Full 6-DOF free camera with mouse look & positioning

local FPCamera = {}

FPCamera.entity = nil
FPCamera.entityID = nil
FPCamera.component = nil
FPCamera.active = false
FPCamera.path = "base\\entities\\cameras\\simple_free_camera.ent"

-- Mode state
FPCamera.mode = 0 -- 0: FP, 1: TP Orbit, 2: Cinematic, 3: Free
FPCamera.prevMode = -1
FPCamera.presetIndex = 0

-- First-person mouse angles (relative to head in local space)
FPCamera.fpYaw = 0.0
FPCamera.fpPitch = 0.0

-- Third-person spherical orbit angles (relative to scene center)
FPCamera.tpYaw = 0.0
FPCamera.tpPitch = 12.0
FPCamera.tpDist = 2.4

-- Bone axis vector table (pure Lua tables at file scope so CET boots safely before RTTI initializes)
FPCamera.axisVectors = {
    [1] = { x = -1.0, y =  0.0, z =  0.0 }, -- -X
    [2] = { x =  1.0, y =  0.0, z =  0.0 }, -- +X
    [3] = { x =  0.0, y = -1.0, z =  0.0 }, -- -Y
    [4] = { x =  0.0, y =  1.0, z =  0.0 }, -- +Y
    [5] = { x =  0.0, y =  0.0, z = -1.0 }, -- -Z
    [6] = { x =  0.0, y =  0.0, z =  1.0 }, -- +Z
}
FPCamera.axisNames = { "-X", "+X", "-Y", "+Y", "-Z", "+Z" }

-- First-person calibration properties
FPCamera.axisForwardIdx = 3 -- -Y
FPCamera.axisUpIdx = 2      -- +X
FPCamera.axisRightIdx = 5   -- -Z
FPCamera.fpOffsetForward = 0.08
FPCamera.fpOffsetUp = 0.05
FPCamera.fpOffsetRight = 0.00
FPCamera.fpRollOffset = 0.0
FPCamera.fpPitchOffset = 0.0
FPCamera.fpYawOffset = 0.0
FPCamera.fpFOV = 65.0

-- Smoothing / 1-to-1 Raw Velocity option
FPCamera.smoothing = false -- false = 100% 1-to-1 instant raw velocity, true = interpolated
FPCamera.smoothFactor = 0.25
FPCamera.lastEyePos = nil

-- Third-person calibration properties
FPCamera.tpLookYawOffset = -90.0 -- 90 degrees to the right to face center directly
FPCamera.tpLookPitchOffset = 0.0

-- Free cam position & rotation
FPCamera.freePos = nil
FPCamera.freeYaw = 0.0
FPCamera.freePitch = 0.0

function FPCamera.Spawn(initialPos, initialYaw)
    FPCamera.Despawn()
    FPCamera.fpYaw = 0.0
    FPCamera.fpPitch = 0.0
    FPCamera.tpYaw = 0.0
    FPCamera.tpPitch = 12.0
    FPCamera.tpDist = 2.4
    FPCamera.freePos = nil

    local player = Game.GetPlayer()
    local pos = initialPos or (player and player:GetWorldPosition()) or Vector4.new(0, 0, 0, 1)
    local spawnTransform = WorldTransform.new()
    spawnTransform:SetPosition(pos)

    if exEntitySpawner and exEntitySpawner.Spawn then
        local ok, id = pcall(function()
            return exEntitySpawner.Spawn(FPCamera.path, spawnTransform, '')
        end)
        if ok and id then
            FPCamera.entityID = id
            print("[NightScene] SceneCamera: Spawning AMM camera entity -> " .. tostring(id))
        else
            print("[NightScene] ERROR: Failed to spawn AMM camera: " .. tostring(id))
        end
    else
        print("[NightScene] ERROR: exEntitySpawner not available for SceneCamera")
    end
end

local function transformLocalOffset(localVec, q)
    local qx, qy, qz, qw = q.i, q.j, q.k, q.r
    -- 2 * cross(q.xyz, v)
    local tx = 2.0 * (qy * localVec.z - qz * localVec.y)
    local ty = 2.0 * (qz * localVec.x - qx * localVec.z)
    local tz = 2.0 * (qx * localVec.y - qy * localVec.x)
    -- v + qw * t + cross(q.xyz, t)
    local rx = localVec.x + qw * tx + (qy * tz - qz * ty)
    local ry = localVec.y + qw * ty + (qz * tx - qx * tz)
    local rz = localVec.z + qw * tz + (qx * ty - qy * tx)
    return Vector4.new(rx, ry, rz, 0.0)
end

local function toModeInt(camMode)
    if camMode == nil then return 0 end
    if type(camMode) == "number" then return camMode end
    if type(camMode) == "userdata" or type(camMode) == "table" then
        if camMode.value ~= nil then
            if type(camMode.value) == "number" then return camMode.value end
            local s = tostring(camMode.value)
            if s == "FirstPerson" or s == "0" then return 0 end
            if s == "ThirdPerson" or s == "1" then return 1 end
            if s == "Cinematic" or s == "2" then return 2 end
            if s == "Free" or s == "3" then return 3 end
        end
    end
    local s = tostring(camMode)
    if string.find(s, "FirstPerson") then return 0 end
    if string.find(s, "ThirdPerson") then return 1 end
    if string.find(s, "Cinematic") then return 2 end
    if string.find(s, "Free") then return 3 end
    return tonumber(s) or 0
end

function FPCamera.SetMode(newMode)
    local targetMode = toModeInt(newMode)
    if targetMode ~= FPCamera.mode then
        FPCamera.prevMode = FPCamera.mode
        FPCamera.mode = targetMode

        if FPCamera.mode == 0 then
            FPCamera.fpYaw = 0.0
            FPCamera.fpPitch = 0.0
        elseif FPCamera.mode == 1 then
            FPCamera.tpYaw = 0.0
            FPCamera.tpPitch = 12.0
            FPCamera.tpDist = 2.4
        elseif FPCamera.mode == 3 then
            FPCamera.freePos = nil
        end
    end
    print(string.format("[NightScene] FPCamera mode set to: %d", FPCamera.mode))
    return FPCamera.mode
end

function FPCamera.CycleMode()
    local nxt = 0
    if FPCamera.mode == 0 then
        nxt = 1
    elseif FPCamera.mode == 1 then
        nxt = 3
    else
        nxt = 0
    end
    return FPCamera.SetMode(nxt)
end

function FPCamera.NextPreset()
    if FPCamera.mode ~= 2 then
        FPCamera.SetMode(2)
        FPCamera.presetIndex = 0
    else
        FPCamera.presetIndex = (FPCamera.presetIndex + 1) % 6
    end
    print(string.format("[NightScene] FPCamera preset set to: %d", FPCamera.presetIndex))
    return FPCamera.presetIndex
end

function FPCamera.OnUpdate(modeInt, presetIdx, clone, originPos, originYaw)
    if modeInt ~= nil then
        local targetMode = toModeInt(modeInt)
        if targetMode ~= FPCamera.mode then
            FPCamera.SetMode(targetMode)
        end
    end
    if presetIdx ~= nil then
        FPCamera.presetIndex = (presetIdx or 0) % 6
    end

    -- Re-acquire and activate AMM camera component if entity spawned
    if FPCamera.entityID and not FPCamera.entity then
        local ent = Game.FindEntityByID(FPCamera.entityID)
        if ent then
            FPCamera.entity = ent
            FPCamera.component = ent:FindComponentByName("camera")
            if FPCamera.component then
                FPCamera.component:Activate(0.0, false)
                FPCamera.active = true
                print("[NightScene] SceneCamera: AMM Camera activated (Mode: " .. tostring(FPCamera.mode) .. ")")
            end
        end
    end

    if not (FPCamera.active and FPCamera.entity) then return end

    -- Extract V clone head bone and body orientation
    local headPos = nil
    local headQuat = nil
    local cloneYaw = originYaw or 0.0
    local clonePos = originPos

    if clone then
        local cloneEuler = clone:GetWorldOrientation():ToEulerAngles()
        cloneYaw = cloneEuler.yaw
        clonePos = clone:GetWorldPosition()

        local slotComp = clone:FindComponentByName(CName.new("ItemAttachmentSlots")) or clone.slotComponent
        if slotComp then
            local ok, headTransform = slotComp:GetSlotTransform(CName.new("Head"))
            if ok and headTransform and headTransform.Position then
                headPos = headTransform.Position:ToVector4()
                headQuat = headTransform.Orientation
            end
        end
    end

    -- Target focal point for ThirdPerson & Cinematic framing (stable at interaction chest height)
    local targetFocus = nil
    if clonePos then
        targetFocus = Vector4.new(clonePos.x, clonePos.y, clonePos.z + 0.85, 1.0)
    elseif headPos then
        targetFocus = Vector4.new(headPos.x, headPos.y, headPos.z - 0.2, 1.0)
    else
        local p = Game.GetPlayer()
        local pp = p and p:GetWorldPosition() or Vector4.new(0, 0, 0, 1)
        targetFocus = Vector4.new(pp.x, pp.y, pp.z + 0.85, 1.0)
    end

    local activeCamPos = nil
    local activeCamRot = nil

    if FPCamera.mode == 0 then
        -- ============================================================
        -- Mode 0: FIRST PERSON (100% 3D Head Bone Tracking & Natural Roll/Pitch)
        -- ============================================================
        if headPos and headQuat then
            local fwdVec   = FPCamera.axisVectors[FPCamera.axisForwardIdx] or Vector4.new(-1.0, 0.0, 0.0, 0.0)
            local upVec    = FPCamera.axisVectors[FPCamera.axisUpIdx] or Vector4.new(0.0, 1.0, 0.0, 0.0)
            local rightVec = FPCamera.axisVectors[FPCamera.axisRightIdx] or Vector4.new(0.0, 0.0, 1.0, 0.0)

            local fwdWorld   = transformLocalOffset(fwdVec, headQuat)
            local upWorld    = transformLocalOffset(upVec, headQuat)
            local rightWorld = transformLocalOffset(rightVec, headQuat)

            local eyePos = Vector4.new(
                headPos.x + (fwdWorld.x * FPCamera.fpOffsetForward) + (upWorld.x * FPCamera.fpOffsetUp) + (rightWorld.x * FPCamera.fpOffsetRight),
                headPos.y + (fwdWorld.y * FPCamera.fpOffsetForward) + (upWorld.y * FPCamera.fpOffsetUp) + (rightWorld.y * FPCamera.fpOffsetRight),
                headPos.z + (fwdWorld.z * FPCamera.fpOffsetForward) + (upWorld.z * FPCamera.fpOffsetUp) + (rightWorld.z * FPCamera.fpOffsetRight),
                1.0
            )

            if FPCamera.smoothing and FPCamera.lastEyePos then
                local alpha = math.min(1.0, math.max(0.01, FPCamera.smoothFactor or 0.25))
                eyePos = Vector4.new(
                    FPCamera.lastEyePos.x + (eyePos.x - FPCamera.lastEyePos.x) * alpha,
                    FPCamera.lastEyePos.y + (eyePos.y - FPCamera.lastEyePos.y) * alpha,
                    FPCamera.lastEyePos.z + (eyePos.z - FPCamera.lastEyePos.z) * alpha,
                    1.0
                )
            end
            FPCamera.lastEyePos = eyePos

            local fwdLenHoriz = math.sqrt(fwdWorld.x * fwdWorld.x + fwdWorld.y * fwdWorld.y)
            local headYaw   = math.deg(math.atan2(fwdWorld.y, fwdWorld.x)) - 90.0 + FPCamera.fpYawOffset
            local headPitch = math.deg(math.atan2(fwdWorld.z, math.max(0.001, fwdLenHoriz))) + FPCamera.fpPitchOffset
            local headRoll  = math.deg(math.atan2(rightWorld.z, math.max(0.001, upWorld.z))) + FPCamera.fpRollOffset

            local camEntityRot = EulerAngles.new(headRoll, headPitch, headYaw)
            Game.GetTeleportationFacility():Teleport(FPCamera.entity, eyePos, camEntityRot)
            activeCamPos = eyePos
            activeCamRot = camEntityRot

            if FPCamera.component then
                local rotEuler = EulerAngles.new(0.0, FPCamera.fpPitch, FPCamera.fpYaw)
                FPCamera.component:SetLocalOrientation(rotEuler:ToQuat())
                FPCamera.component:SetFOV(FPCamera.fpFOV)
            end
        end

    elseif FPCamera.mode == 1 then
        -- ============================================================
        -- Mode 1: THIRD PERSON (360° Spherical Orbit Around Lovers)
        -- ============================================================
        local orbitAngle = (cloneYaw + 180.0 + FPCamera.tpYaw) % 360.0
        local yawRad = math.rad(orbitAngle)
        local pitchRad = math.rad(FPCamera.tpPitch)
        local dist = FPCamera.tpDist

        local camX = targetFocus.x + (dist * math.cos(pitchRad) * math.cos(yawRad))
        local camY = targetFocus.y + (dist * math.cos(pitchRad) * math.sin(yawRad))
        local camZ = targetFocus.z + (dist * math.sin(pitchRad))
        local camPos = Vector4.new(camX, camY, camZ, 1.0)

        -- LookAt calculation towards targetFocus (+90 deg offset to face couple directly)
        local dx = targetFocus.x - camPos.x
        local dy = targetFocus.y - camPos.y
        local dz = targetFocus.z - camPos.z
        local distHoriz = math.sqrt(dx * dx + dy * dy)
        local lookYaw = math.deg(math.atan2(dy, dx)) + FPCamera.tpLookYawOffset
        local lookPitch = math.deg(math.atan2(dz, math.max(0.001, distHoriz))) + FPCamera.tpLookPitchOffset

        local camEntityRot = EulerAngles.new(0.0, lookPitch, lookYaw)
        Game.GetTeleportationFacility():Teleport(FPCamera.entity, camPos, camEntityRot)
        activeCamPos = camPos
        activeCamRot = camEntityRot

        if FPCamera.component then
            FPCamera.component:SetLocalOrientation(Quaternion.new(0, 0, 0, 1))
            FPCamera.component:SetFOV(65.0)
        end

    elseif FPCamera.mode == 2 then
        -- ============================================================
        -- Mode 2: CINEMATIC (Oriented to V Clone & Partner, Locked Inputs)
        -- ============================================================
        local presets = {
            [0] = { angle = 0.0,   dist = 1.8,  height = 0.3,  fov = 55.0 }, -- Front Center
            [1] = { angle = 35.0,  dist = 1.4,  height = 0.2,  fov = 50.0 }, -- Front 3/4 Intimate
            [2] = { angle = 90.0,  dist = 1.6,  height = 0.25, fov = 55.0 }, -- Left Flank Profile
            [3] = { angle = -90.0, dist = 1.6,  height = 0.25, fov = 55.0 }, -- Right Flank Profile
            [4] = { angle = 180.0, dist = 1.2,  height = 1.5,  fov = 65.0 }, -- Overhead Top-Down
            [5] = { angle = 30.0,  dist = 1.3,  height = -0.35,fov = 55.0 }, -- Low Ground Sensual
        }

        local p = presets[FPCamera.presetIndex] or presets[0]
        local angleDeg = (cloneYaw + p.angle) % 360.0
        local angleRad = math.rad(angleDeg)

        local camX = targetFocus.x + (p.dist * math.cos(angleRad))
        local camY = targetFocus.y + (p.dist * math.sin(angleRad))
        local camZ = targetFocus.z + p.height
        local camPos = Vector4.new(camX, camY, camZ, 1.0)

        -- Focus look directly at couple interaction center (+90 deg offset to face couple directly)
        local dx = targetFocus.x - camPos.x
        local dy = targetFocus.y - camPos.y
        local dz = targetFocus.z - camPos.z
        local distHoriz = math.sqrt(dx * dx + dy * dy)
        local lookYaw = math.deg(math.atan2(dy, dx)) - 90.0
        local lookPitch = math.deg(math.atan2(dz, math.max(0.001, distHoriz)))

        local camEntityRot = EulerAngles.new(0.0, lookPitch, lookYaw)
        Game.GetTeleportationFacility():Teleport(FPCamera.entity, camPos, camEntityRot)
        activeCamPos = camPos
        activeCamRot = camEntityRot

        if FPCamera.component then
            FPCamera.component:SetLocalOrientation(Quaternion.new(0, 0, 0, 1))
            FPCamera.component:SetFOV(p.fov)
        end

    elseif FPCamera.mode == 3 then
        -- ============================================================
        -- Mode 3: FREE CAM (Free 6-DOF Movement)
        -- ============================================================
        if not FPCamera.freePos then
            local fwdRad = math.rad(cloneYaw)
            FPCamera.freePos = Vector4.new(
                targetFocus.x + (2.0 * math.cos(fwdRad)),
                targetFocus.y + (2.0 * math.sin(fwdRad)),
                targetFocus.z + 0.3,
                1.0
            )
            FPCamera.freeYaw = (cloneYaw + 180.0) % 360.0
            FPCamera.freePitch = -8.0
        end

        local camEntityRot = EulerAngles.new(0.0, FPCamera.freePitch, FPCamera.freeYaw - 90.0)
        Game.GetTeleportationFacility():Teleport(FPCamera.entity, FPCamera.freePos, camEntityRot)
        activeCamPos = FPCamera.freePos
        activeCamRot = camEntityRot

        if FPCamera.component then
            FPCamera.component:SetLocalOrientation(Quaternion.new(0, 0, 0, 1))
            FPCamera.component:SetFOV(65.0)
        end
    end

    -- Colocate real player puppet (the primary audio listener) with the active camera
    -- ONLY do this when scene is actively playing (vClone is spawned and workspot is ready)
    local okSpawner, Spawner = pcall(require, "modules/workspot_spawner")
    local sceneIsPlaying = okSpawner and Spawner and (not Spawner.polling) and (Spawner.workspotEntity ~= nil) and ((Spawner.vCloneID == nil) or (Spawner.vClone ~= nil))

    if sceneIsPlaying and activeCamPos and activeCamRot then
        pcall(function()
            local player = Game.GetPlayer()
            if player then
                -- Place player puppet 0.6m behind the camera direction so the camera is in front of the player's body
                -- This guarantees that the player's arms, legs, and torso are completely behind the camera lens
                -- while keeping the audio listener within inches of the camera viewpoint!
                local camYawRad = math.rad(activeCamRot.yaw or 0.0)
                local camPitchRad = math.rad(activeCamRot.pitch or 0.0)
                local fwdX = math.cos(camPitchRad) * math.sin(camYawRad)
                local fwdY = -math.cos(camPitchRad) * math.cos(camYawRad)
                local fwdZ = math.sin(camPitchRad)

                local offsetDist = 0.6
                local playerPos = Vector4.new(
                    activeCamPos.x - (fwdX * offsetDist),
                    activeCamPos.y - (fwdY * offsetDist),
                    activeCamPos.z - (fwdZ * offsetDist),
                    1.0
                )
                Game.GetTeleportationFacility():Teleport(player, playerPos, activeCamRot)
            end
        end)
    end
end

function FPCamera.HandleInput(actionName, actionType, action)
    if not FPCamera.active or not FPCamera.component then return end

    -- Mode 2: CINEMATIC - Input is completely locked to preserve the cinematic shot
    if FPCamera.mode == 2 then
        return
    end

    if FPCamera.mode == 0 then
        -- FirstPerson: mouse look in head bone local space
        if actionName == "CameraMouseX" or actionName == "CameraX" or actionName == "PhotoMode_CameraMouseX" then
            local x = action:GetValue(action)
            FPCamera.fpYaw = FPCamera.fpYaw - (x / 45.0)
        elseif actionName == "CameraMouseY" or actionName == "CameraY" or actionName == "PhotoMode_CameraMouseY" then
            local y = action:GetValue(action)
            FPCamera.fpPitch = math.max(-85.0, math.min(85.0, FPCamera.fpPitch + (y / 45.0)))
        end

    elseif FPCamera.mode == 1 then
        -- ThirdPerson: 360 orbit mouse control & zoom (inverted horizontal & vertical)
        if actionName == "CameraMouseX" or actionName == "CameraX" or actionName == "PhotoMode_CameraMouseX" then
            local x = action:GetValue(action)
            FPCamera.tpYaw = (FPCamera.tpYaw + (x / 30.0)) % 360.0
        elseif actionName == "CameraMouseY" or actionName == "CameraY" or actionName == "PhotoMode_CameraMouseY" then
            local y = action:GetValue(action)
            FPCamera.tpPitch = math.max(-80.0, math.min(85.0, FPCamera.tpPitch - (y / 30.0)))
        elseif actionName == "CameraMouseWheel" or actionName == "MouseWheel" then
            local z = action:GetValue(action)
            FPCamera.tpDist = math.max(0.6, math.min(8.0, FPCamera.tpDist - (z * 0.2)))
        end

    elseif FPCamera.mode == 3 then
        -- FreeCam: mouse look & free positioning
        if actionName == "CameraMouseX" or actionName == "CameraX" or actionName == "PhotoMode_CameraMouseX" then
            local x = action:GetValue(action)
            FPCamera.freeYaw = (FPCamera.freeYaw - (x / 30.0)) % 360.0
        elseif actionName == "CameraMouseY" or actionName == "CameraY" or actionName == "PhotoMode_CameraMouseY" then
            local y = action:GetValue(action)
            FPCamera.freePitch = math.max(-85.0, math.min(85.0, FPCamera.freePitch + (y / 30.0)))
        end
    end
end

function FPCamera.Deactivate()
    if FPCamera.active and FPCamera.component then
        FPCamera.active = false
        pcall(function() FPCamera.component:Deactivate(0.0, false) end)
        pcall(function()
            local player = Game.GetPlayer()
            if player then
                local fppCam = player:GetFPPCameraComponent()
                if fppCam then fppCam:Activate(0.0, false) end
            end
        end)
    end
end

function FPCamera.Despawn()
    FPCamera.Deactivate()
    if FPCamera.entity then
        pcall(function() exEntitySpawner.Despawn(FPCamera.entity) end)
        FPCamera.entity = nil
        FPCamera.entityID = nil
        FPCamera.component = nil
        print("[NightScene] SceneCamera: AMM Camera despawned")
    end
    FPCamera.freePos = nil
    FPCamera.lastEyePos = nil
end

function FPCamera.LogCurrentOrientation(clone, originPos, originYaw)
    local headPos = nil
    local headQuat = nil
    local cloneYaw = originYaw or 0.0
    local clonePos = originPos

    if clone then
        local cloneEuler = clone:GetWorldOrientation():ToEulerAngles()
        cloneYaw = cloneEuler.yaw
        clonePos = clone:GetWorldPosition()

        local slotComp = clone:FindComponentByName(CName.new("ItemAttachmentSlots")) or clone.slotComponent
        if slotComp then
            local ok, headTransform = slotComp:GetSlotTransform(CName.new("Head"))
            if ok and headTransform and headTransform.Position then
                headPos = headTransform.Position:ToVector4()
                headQuat = headTransform.Orientation
            end
        end
    end

    local logStr = ""

    if FPCamera.mode == 0 then
        -- First person from head bone: "first person, <roll>, <pitch>, <yaw>"
        if headQuat then
            local fwdWorld   = transformLocalOffset(Vector4.new(-1.0, 0.0, 0.0, 0.0), headQuat)
            local upWorld    = transformLocalOffset(Vector4.new(0.0, 1.0, 0.0, 0.0), headQuat)
            local rightWorld = transformLocalOffset(Vector4.new(0.0, 0.0, 1.0, 0.0), headQuat)

            local fwdLenHoriz = math.sqrt(fwdWorld.x * fwdWorld.x + fwdWorld.y * fwdWorld.y)
            local headYaw   = math.deg(math.atan2(fwdWorld.y, fwdWorld.x))
            local headPitch = math.deg(math.atan2(fwdWorld.z, math.max(0.001, fwdLenHoriz)))
            local headRoll  = math.deg(math.atan2(rightWorld.z, math.max(0.001, upWorld.z)))

            logStr = string.format("first person, %.1f, %.1f, %.1f", headRoll, headPitch, headYaw)
        else
            logStr = string.format("first person, %.1f, %.1f, %.1f", 0.0, FPCamera.fpPitch, FPCamera.fpYaw)
        end

    elseif FPCamera.mode == 1 then
        -- Third person from scene center: "third person, <pitch>, <yaw>, <roll>"
        local orbitAngle = (cloneYaw + 180.0 + FPCamera.tpYaw) % 360.0
        logStr = string.format("third person, %.1f, %.1f, %.1f (dist: %.2f)", FPCamera.tpPitch, orbitAngle, 0.0, FPCamera.tpDist)

    elseif FPCamera.mode == 2 then
        -- Cinematic from V clone
        local presets = {
            [0] = { name = "Front Center", angle = 0.0 },
            [1] = { name = "Front 3/4",    angle = 35.0 },
            [2] = { name = "Left Flank",   angle = 90.0 },
            [3] = { name = "Right Flank",  angle = -90.0 },
            [4] = { name = "Overhead",     angle = 180.0 },
            [5] = { name = "Low Ground",   angle = 30.0 },
        }
        local p = presets[FPCamera.presetIndex] or presets[0]
        local angleDeg = (cloneYaw + p.angle) % 360.0
        logStr = string.format("cinematic [%s], %.1f, %.1f, %.1f", p.name, angleDeg, 0.0, 0.0)

    elseif FPCamera.mode == 3 then
        -- Free Cam
        logStr = string.format("free cam, %.1f, %.1f, %.1f", FPCamera.freePitch, FPCamera.freeYaw, 0.0)
    end

    print("[NightScene] " .. logStr)
    return logStr
end

function FPCamera.PrintCalibration()
    local str = string.format([[
[NightScene Camera Calibration]
-- First Person:
Forward Axis: %s, Up Axis: %s, Right Axis: %s
Offset: Forward=%.2f, Up=%.2f, Right=%.2f
Angles: Roll=%.1f, Pitch=%.1f, Yaw=%.1f, FOV=%.0f
-- Third Person:
LookYawOffset=%.1f, LookPitchOffset=%.1f]],
        FPCamera.axisNames[FPCamera.axisForwardIdx] or "?",
        FPCamera.axisNames[FPCamera.axisUpIdx] or "?",
        FPCamera.axisNames[FPCamera.axisRightIdx] or "?",
        FPCamera.fpOffsetForward, FPCamera.fpOffsetUp, FPCamera.fpOffsetRight,
        FPCamera.fpRollOffset, FPCamera.fpPitchOffset, FPCamera.fpYawOffset, FPCamera.fpFOV,
        FPCamera.tpLookYawOffset, FPCamera.tpLookPitchOffset
    )
    print(str)
    return str
end

function FPCamera.ResetCalibration()
    FPCamera.axisForwardIdx = 3
    FPCamera.axisUpIdx = 2
    FPCamera.axisRightIdx = 5
    FPCamera.fpOffsetForward = 0.08
    FPCamera.fpOffsetUp = 0.05
    FPCamera.fpOffsetRight = 0.00
    FPCamera.fpRollOffset = 0.0
    FPCamera.fpPitchOffset = 0.0
    FPCamera.fpYawOffset = 0.0
    FPCamera.fpFOV = 65.0
    FPCamera.tpLookYawOffset = -90.0
    FPCamera.tpLookPitchOffset = 0.0
end

return FPCamera
