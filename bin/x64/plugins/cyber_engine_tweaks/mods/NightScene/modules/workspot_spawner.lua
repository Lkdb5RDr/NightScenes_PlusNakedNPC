-- NightScene Framework - Workspot Spawner
-- ==========================================
-- Uses ONE shared workspot entity for all actors.
-- V clone replaces real V for animation compatibility.
-- Stripped down to minimal working state -- no hiding, no equipment stripping.

local Config = require("modules/config")

local WorkspotSpawner = {}

-- Explicit-entity swap: NPCs covered by BONeill's explicit mod get replaced by
-- their nude counterpart for the scene instead of being stripped in place.
local okSwap, ExplicitSwap = pcall(require, "modules/explicit_swap")
if not okSwap then
    print("[NightScene] Spawner: ERROR loading explicit swap: " .. tostring(ExplicitSwap))
    ExplicitSwap = {
        Begin = function() return nil end, OnUpdate = function() end,
        AllReady = function() return true end, GetStandIn = function() return nil end,
        FindRecord = function() return nil end, IsActive = function() return false end,
        StandIns = function() return {} end, RestoreAll = function() end,
    }
end

WorkspotSpawner.workspotEntity = nil
WorkspotSpawner.workspotEntityID = nil
WorkspotSpawner.vClone = nil
WorkspotSpawner.vCloneID = nil
WorkspotSpawner.actorCount = 0
WorkspotSpawner.polling = false
WorkspotSpawner.pollTicks = 0
WorkspotSpawner.readyTick = nil
WorkspotSpawner.preStripped = nil
-- Entity IDs of non-player actors, captured while the scene is still active
-- (Cleanup() runs after the scene may already have ended redscript-side, at
-- which point NightSceneAPI::GetSceneActor always returns null)
WorkspotSpawner.npcActorIDs = {}

function WorkspotSpawner.OnUpdate()
    -- Handle delayed player restore (prevents air assassination on clone)
    if WorkspotSpawner.restorePending and WorkspotSpawner.restoreDelay then
        WorkspotSpawner.restoreDelay = WorkspotSpawner.restoreDelay - 1
        if WorkspotSpawner.restoreDelay <= 0 then
            pcall(function()
                -- The player used to be shoved 5m forward here. It was a blind
                -- offset with no collision check, so it regularly pushed V into
                -- walls and geometry. Removed -- V now just stays put.
                Game['NightSceneAPI::RestorePlayerFromScene;']()
                print("[NightScene] Spawner: Player restored")
            end)
            WorkspotSpawner.restorePending = nil
            WorkspotSpawner.restoreDelay = nil
        end
    end

    if not WorkspotSpawner.polling then return end

    WorkspotSpawner.pollTicks = WorkspotSpawner.pollTicks + 1

    if WorkspotSpawner.pollTicks > 1800 then
        print("[NightScene] Spawner: Timed out")
        WorkspotSpawner.polling = false
        -- Never leave a hidden NPC behind because a stand-in failed to stream
        -- in -- that would be an invisible NPC standing in the world for good.
        pcall(function() ExplicitSwap.RestoreAll() end)
        return
    end

    -- Deferred Clone V spawn: counted down every frame (not on the 5-tick
    -- cadence below) so the wait stays short and predictable.
    if WorkspotSpawner.pendingCloneDelay then
        WorkspotSpawner.pendingCloneDelay = WorkspotSpawner.pendingCloneDelay - 1
        if WorkspotSpawner.pendingCloneDelay <= 0 then
            local recordID = WorkspotSpawner.pendingCloneRecord
            WorkspotSpawner.pendingCloneDelay = nil
            WorkspotSpawner.pendingCloneRecord = nil

            pcall(function()
                local player = Game.GetPlayer()
                local spec = DynamicEntitySpec.new()
                spec.recordID = TweakDBID.new(recordID)
                spec.persistState = false
                spec.persistSpawn = false
                spec.alwaysSpawned = true
                spec.spawnInView = true
                spec.position = player:GetWorldPosition()
                spec.orientation = player:GetWorldOrientation()

                WorkspotSpawner.vCloneID = Game.GetDynamicEntitySystem():CreateEntity(spec)
                print("[NightScene] Spawner: Clone V spawning (player unequipped)")

                -- Hide the real V only NOW, once the clone has been created
                -- from the player's state. Hiding first produced a clone
                -- missing the Equipment-EX outfit. The per-frame re-apply in
                -- init.lua keeps it hidden from here on.
                WorkspotSpawner.HidePlayer()
            end)
        end
    end

    if WorkspotSpawner.pollTicks % 5 ~= 0 then return end

    -- Check V clone
    if WorkspotSpawner.vCloneID and not WorkspotSpawner.vClone then
        local ent = Game.FindEntityByID(WorkspotSpawner.vCloneID)
        if ent then
            WorkspotSpawner.vClone = ent
            print("[NightScene] Spawner: V clone ready (TPP_Body nude appearance)")
        end
    end

    -- Resolve explicit stand-ins and hide the NPCs they replace
    pcall(ExplicitSwap.OnUpdate)

    -- Check workspot entity
    if WorkspotSpawner.workspotEntityID and not WorkspotSpawner.workspotEntity then
        local ent = Game.FindEntityByID(WorkspotSpawner.workspotEntityID)
        if ent then
            WorkspotSpawner.workspotEntity = ent
            print("[NightScene] Spawner: Workspot entity ready")
        end
    end

    local wsReady = (WorkspotSpawner.workspotEntity ~= nil)
    -- A clone still waiting to be spawned has no vCloneID yet, so it must be
    -- checked explicitly -- otherwise the scene would start without it.
    local cloneReady = (WorkspotSpawner.pendingCloneDelay == nil)
        and ((WorkspotSpawner.vCloneID == nil) or (WorkspotSpawner.vClone ~= nil))
    local swapsReady = ExplicitSwap.AllReady()

    if wsReady and cloneReady and swapsReady then
        if not WorkspotSpawner.readyTick then
            WorkspotSpawner.readyTick = os.clock()
            return
        end

        local elapsed = os.clock() - WorkspotSpawner.readyTick

        -- Pre-strip NPCs at 0.1s — appearance system still free before PlayAll
        if elapsed >= 0.1 and not WorkspotSpawner.preStripped then
            WorkspotSpawner.preStripped = true
            local nakedMod = GetMod("NakedNPC")
            if nakedMod and nakedMod.StripForScene then
                print("[NightScene] Spawner: Pre-stripping NPCs before PlayAll...")
                for i = 0, WorkspotSpawner.actorCount - 1 do
                    local isPlayer = Game['NightSceneAPI::IsActiveSceneActorPlayer;Int32'](i)
                    if not isPlayer then
                        pcall(function()
                            local actor = Game['NightSceneAPI::GetActiveSceneActor;Int32'](i)
                            -- Swapped actors are hidden and played by a nude
                            -- stand-in, so stripping them is pointless work on
                            -- an invisible body -- and it would leave the real
                            -- NPC naked if a restore ever failed.
                            if actor and not ExplicitSwap.GetStandIn(actor) then
                                nakedMod.StripForScene(actor, "erect")
                                print("[NightScene] Spawner: Pre-stripped actor " .. tostring(i))
                            end
                        end)
                    end
                end
            end
        end

        -- Clone V strip: Character.TPP_Player_Cutscene_Male/Female always reports
        -- an empty GetCurrentAppearanceName(), so the normal appearance-cycle
        -- strip (StripForScene) can never succeed on it -- confirmed by logs
        -- showing "cycle failed to start" on every retry for the full window.
        -- StripCloneV uses direct component toggling instead, which doesn't
        -- need an appearance name at all.
        --
        -- Skipped entirely when Equipment-EX is in use: UnequipPlayer already
        -- loaded the nude outfit onto the player BEFORE the clone spawned, and
        -- the clone inherits that state, so this pass has nothing left to strip
        -- (it was reporting "0 items stripped" and just spamming the log).
        if WorkspotSpawner.vClone and not WorkspotSpawner.vCloneStripped then
            local nakedMod = GetMod("NakedNPC")
            if nakedMod and nakedMod.StripCloneV then
                local usingEquipmentEx = nakedMod.HasEquipmentEx and nakedMod.HasEquipmentEx()
                if usingEquipmentEx then
                    WorkspotSpawner.vCloneStripped = true
                    print("[NightScene] Spawner: Clone V nude via Equipment-EX, skipping component strip")
                else
                    local ok, result = pcall(function()
                        return nakedMod.StripCloneV(WorkspotSpawner.vClone, "erect")
                    end)
                    if ok and result then
                        WorkspotSpawner.vCloneStripped = true
                        print("[NightScene] Spawner: Clone V stripped")
                    end
                end
            end
        end

        -- -- Play after 2.0s — gives the full strip cycle time to complete
        -- if WorkspotSpawner.preStripped then
        --     local nakedMod = GetMod("NakedNPC")
        --     local allStripped = true
        --     for i = 0, WorkspotSpawner.actorCount - 1 do
        --         local isPlayer = Game['NightSceneAPI::IsActiveSceneActorPlayer;Int32'](i)
        --         if not isPlayer then
        --             local actor = Game['NightSceneAPI::GetActiveSceneActor;Int32'](i)
        --             if actor and nakedMod and not nakedMod.IsStripped(actor) then
        --                 allStripped = false
        --                 break
        --             end
        --         end
        --     end

        --     if not allStripped then
        --         if elapsed < 10.0 then return end
        --         print("[NightScene] Spawner: Strip timeout after 10s, playing anyway")
        --     end
        -- else
        --     -- Pre-strip hasn't fired yet, keep waiting
        --     return
        -- end

        if elapsed < 3.0 then return end

        WorkspotSpawner.polling = false
        WorkspotSpawner.readyTick = nil
        WorkspotSpawner.preStripped = nil
        print("[NightScene] Spawner: Playing...")
        WorkspotSpawner.PlayAll()
    end
end


-- ------------------------------------------------------------
--  CLONE HEAD VISIBILITY (first-person camera)
-- ------------------------------------------------------------
-- Ported from the Jonatan fork. In first-person the camera sits at the clone's
-- head bone, so the clone's own head, face and hair have to be hidden or the
-- view is filled with the inside of its skull. Every other camera mode shows
-- the head normally.
--
-- Hiding happens in two passes because a head is assembled from two places:
-- equipped item entities in the head attachment slots (eyes, teeth, tongue,
-- hair, accessories), and mesh components directly on the puppet.

local headSlots = {
    "AttachmentSlots.TppHead",
    "AttachmentSlots.Head",
    "AttachmentSlots.Eyes",
    "AttachmentSlots.Face",
    "AttachmentSlots.Hair",
    "AttachmentSlots.Beard",
    "AttachmentSlots.HeadCyberware",
    "AttachmentSlots.PersonalLink",
    "AttachmentSlots.Eyewear",
    "OutfitSlots.Head",
    "OutfitSlots.Balaclava",
    "OutfitSlots.Mask",
    "OutfitSlots.Glasses",
    "OutfitSlots.Eyes",
    "OutfitSlots.EyeLeft",
    "OutfitSlots.EyeRight",
    "OutfitSlots.Wreath",
    "OutfitSlots.EarLeft",
    "OutfitSlots.EarRight",
    "OutfitSlots.Face",
    "OutfitSlots.Neckwear",
    "OutfitSlots.Necklace",
    "OutfitSlots.NecklaceTight",
    "OutfitSlots.NecklaceShort",
    "OutfitSlots.NecklaceLong",
}

local cloneHeadSavedChunkMasks = {}

local function isCloneHeadOrFaceComponent(comp)
    local cName = Game.NameToString(comp:GetName()):lower()
    local cClass = Game.NameToString(comp:GetClassName())

    -- 1. Absolute exemptions: never hide body meshes, limbs, hands, feet, or genitals
    if cName:find("penis") or cName:find("vagina") or cName:find("genital")
        or cName:find("groin") or cName:find("crotch") or cName:find("dicks")
        or cName:find("t0_") or cName:find("l0_") or cName:find("s0_")
        or cName:find("torso") or cName:find("chest") or cName:find("breast")
        or cName:find("belly") or cName:find("arm") or cName:find("hand")
        or cName:find("wrist") or cName:find("finger") or cName:find("leg")
        or cName:find("foot") or cName:find("feet") or cName:find("ankle")
        or cName:find("tpp_body") then
        return false
    end

    -- 2. Explicit head / face / headwear / accessory prefixes
    local p3 = cName:sub(1, 3)
    if p3 == "h0_" or p3 == "h1_" or p3 == "h2_" or p3 == "hx_" or p3 == "ht_" or p3 == "he_" or p3 == "hh_" or p3 == "i1_" then
        return true
    end

    -- 3. Keywords matching head, hair, face, facial features, facial accessories, and eyewear
    if cName:find("head") or cName:find("hair") or cName:find("beard")
        or cName:find("eye") or cName:find("cornea") or cName:find("sclera") or cName:find("pupil") or cName:find("iris") or cName:find("lash") or cName:find("brow")
        or cName:find("teeth") or cName:find("tooth") or cName:find("tongue") or cName:find("mouth") or cName:find("oral") or cName:find("lip") or cName:find("jaw")
        or cName:find("face") or cName:find("nose") or cName:find("cheek") or cName:find("chin")
        or cName:find("ear") or cName:find("piercing") or cName:find("earring")
        or cName:find("necklace") or cName:find("choker") or cName:find("pendant") or cName:find("chain") or cName:find("collar")
        or cName:find("glass") or cName:find("goggle") or cName:find("visor") or cName:find("mask") or cName:find("wreath")
        or cName:find("balaclava") or cName:find("hat") or cName:find("cap") or cName:find("helmet")
        or cName:find("cw_head") or cName:find("cw_face") or cName:find("kereznikov") then
        return true
    end

    -- 4. Morph target skinned mesh components that are not body parts are head/facial morphs
    if cClass == "entMorphTargetSkinnedMeshComponent" or cName:find("morphtarget") then
        return true
    end

    return false
end

local function isHairComponent(comp)
    local cName = Game.NameToString(comp:GetName()):lower()
    -- Eyelashes and eyebrows belong to the eyes/face and should never float in FP
    if cName:find("brow") or cName:find("lash") then
        return false
    end
    if cName:sub(1, 3) == "hh_" then
        return true
    end
    if cName:find("hair") or cName:find("beard") or cName:find("dread") or cName:find("braid") or cName:find("ponytail") or cName:find("bangs") then
        if not (cName:find("arm") or cName:find("chest") or cName:find("leg") or cName:find("pubic")) then
            return true
        end
    end
    return false
end

-- Counters for the pass below; module-level so both sections add to them.
local cloneHeadHidden, cloneHeadRestored, cloneHeadUnsaved = 0, 0, 0
local cloneSlotHidden, cloneSlotRestored, cloneSlotUnsaved, cloneSlotsWithItem = 0, 0, 0, 0

local function setCloneHeadVisible(clone, visible)
    if not clone then return end

    cloneHeadHidden, cloneHeadRestored, cloneHeadUnsaved = 0, 0, 0
    cloneSlotHidden, cloneSlotRestored, cloneSlotUnsaved, cloneSlotsWithItem = 0, 0, 0, 0

    local keepHair = (Config.current and Config.current.keepHairInFP == true)

    -- 1. Hide/show all meshes on equipped head item entities (eyes, teeth, tongue, mouth, hair, accessories)
    local ts = Game.GetTransactionSystem()
    if ts then
        for _, slotName in ipairs(headSlots) do
            local slotIsHair = (slotName == "AttachmentSlots.Hair" or slotName == "AttachmentSlots.Beard")
            local shouldHideSlot = (not visible)
            if slotIsHair and keepHair then
                shouldHideSlot = false
            end

            pcall(function()
                local slotID = TweakDBID.new(slotName)
                local itemEntity = ts:GetItemInSlot(clone, slotID)
                if itemEntity and itemEntity.GetComponents then
                    cloneSlotsWithItem = cloneSlotsWithItem + 1
                    for _, c in ipairs(itemEntity:GetComponents()) do
                        pcall(function()
                            local cClass = Game.NameToString(c:GetClassName())
                            local cName = Game.NameToString(c:GetName())
                            local key = slotName .. "_" .. cName
                            if string.find(cClass, "Mesh") or cClass == "entMorphTargetSkinnedMeshComponent" then
                                if shouldHideSlot then
                                    if cloneHeadSavedChunkMasks[key] == nil and c.chunkMask ~= nil then
                                        cloneHeadSavedChunkMasks[key] = c.chunkMask
                                    end
                                    c.chunkMask = 0
                                    cloneSlotHidden = cloneSlotHidden + 1
                                else
                                    local orig = cloneHeadSavedChunkMasks[key]
                                    if orig ~= nil then
                                        c.chunkMask = orig
                                        cloneSlotRestored = cloneSlotRestored + 1
                                    else
                                        cloneSlotUnsaved = cloneSlotUnsaved + 1
                                    end
                                end
                            end
                            c.isEnabled = not shouldHideSlot
                            if c.Toggle then c:Toggle(not shouldHideSlot) end
                            if c.TemporaryHide then c:TemporaryHide(shouldHideSlot) end
                        end)
                    end
                end
            end)
        end
    end

    -- 2. Hide/show direct head/face/accessory components on clone puppet
    pcall(function()
        if clone.GetComponents then
            local comps = clone:GetComponents()
            for _, c in ipairs(comps) do
                local cClass = Game.NameToString(c:GetClassName())
                if string.find(cClass, "Mesh") or cClass == "entMorphTargetSkinnedMeshComponent" then
                    if isCloneHeadOrFaceComponent(c) then
                        local isHair = isHairComponent(c)
                        local shouldHideComp = (not visible)
                        if isHair and keepHair then
                            shouldHideComp = false
                        end

                        local cName = Game.NameToString(c:GetName())
                        pcall(function()
                            if shouldHideComp then
                                if cloneHeadSavedChunkMasks[cName] == nil and c.chunkMask ~= nil then
                                    cloneHeadSavedChunkMasks[cName] = c.chunkMask
                                end
                                c.chunkMask = 0
                                cloneHeadHidden = cloneHeadHidden + 1
                            else
                                local orig = cloneHeadSavedChunkMasks[cName]
                                if orig ~= nil then
                                    c.chunkMask = orig
                                    cloneHeadRestored = cloneHeadRestored + 1
                                else
                                    cloneHeadUnsaved = cloneHeadUnsaved + 1
                                end
                            end
                            c.isEnabled = not shouldHideComp
                            if c.Toggle then c:Toggle(not shouldHideComp) end
                            if c.TemporaryHide then c:TemporaryHide(shouldHideComp) end
                        end)
                    end
                end
            end
        end
    end)

    print(string.format(
        "[NightScene] CloneHead: visible=%s | puppet hid %d / restored %d / unsaved %d"
            .. " | %d head slots: hid %d / restored %d / unsaved %d",
        tostring(visible), cloneHeadHidden, cloneHeadRestored, cloneHeadUnsaved,
        cloneSlotsWithItem, cloneSlotHidden, cloneSlotRestored, cloneSlotUnsaved))
end

WorkspotSpawner.SetCloneHeadVisible = setCloneHeadVisible
-- Components on the real V currently hidden for a scene, so they can be put
-- back. Kept as a list of component handles rather than saved chunk masks --
-- TemporaryHide(false) restores whatever the component's own state was.
WorkspotSpawner.hiddenPlayerComponents = {}

--- Hide the real V using the SAME mechanism as the NPC swap, which is the one
--- approach confirmed working in this game: TemporaryHide(true) on every
--- visual component, enumerated through Codeware's GetComponents().
---
--- The chunkMask/isEnabled/Toggle approach ported from the Jonatan fork
--- reported hiding 65 components and V stayed visible regardless of when it
--- ran, so it is no longer used for the player.
---
--- Safe to call repeatedly: already-hidden components are simply hidden again,
--- and newly streamed-in ones get picked up and added to the restore list.
function WorkspotSpawner.HidePlayer()
    local player = Game.GetPlayer()
    if not player then return 0 end

    local hidden = ExplicitSwap.HideEntity(player)
    if not hidden then
        print("[NightScene] Spawner: could not enumerate V's components")
        return 0
    end

    -- Merge, skipping components already tracked, so repeated calls don't grow
    -- the list without bound.
    local known = {}
    for _, comp in ipairs(WorkspotSpawner.hiddenPlayerComponents) do known[comp] = true end
    local added = 0
    for _, comp in ipairs(hidden) do
        if not known[comp] then
            table.insert(WorkspotSpawner.hiddenPlayerComponents, comp)
            added = added + 1
        end
    end

    return added, #WorkspotSpawner.hiddenPlayerComponents
end

--- Put the real V back.
function WorkspotSpawner.ShowPlayer()
    local count = #WorkspotSpawner.hiddenPlayerComponents
    ExplicitSwap.UnhideComponents(WorkspotSpawner.hiddenPlayerComponents)
    WorkspotSpawner.hiddenPlayerComponents = {}
    return count
end

local function getVCloneRecordID()
    local gender = Game.GetPlayer():GetResolvedGenderName()
    local isFemale = tostring(gender):find("Female")
    return isFemale and "Character.TPP_Player_Cutscene_Female" or "Character.TPP_Player_Cutscene_Male"
end

function WorkspotSpawner.SpawnAndPlay()
    local entityPath = Game['NightSceneAPI::GetActiveSceneEntityPath;']()
    local actorCount = Game['NightSceneAPI::GetActiveSceneActorCount;']()

    if not entityPath or entityPath == "" then
        print("[NightScene] Spawner: No entity path")
        return false
    end

    print("[NightScene] Spawner: Entity: " .. entityPath .. " | Actors: " .. tostring(actorCount))

    WorkspotSpawner.workspotEntity = nil
    WorkspotSpawner.workspotEntityID = nil
    WorkspotSpawner.vClone = nil
    WorkspotSpawner.vCloneID = nil
    WorkspotSpawner.pendingCloneDelay = nil
    WorkspotSpawner.pendingCloneRecord = nil
    WorkspotSpawner.actorCount = actorCount
    WorkspotSpawner.readyTick = nil
    WorkspotSpawner.preStripped = nil
    WorkspotSpawner.vCloneStripped = nil
    WorkspotSpawner.npcActorIDs = {}

    -- Check if player is an actor
    local hasPlayer = false
    for i = 0, actorCount - 1 do
        if Game['NightSceneAPI::IsActiveSceneActorPlayer;Int32'](i) then
            hasPlayer = true
            break
        end
    end

    -- Explicit swaps: request a nude stand-in for every NPC actor the explicit
    -- mod covers. Done before anything else spawns so the stand-ins have the
    -- longest possible time to stream in. Uncovered NPCs return nil and go
    -- through the existing NakedNPC pre-strip instead.
    pcall(function() ExplicitSwap.RestoreAll() end)
    for i = 0, actorCount - 1 do
        if not Game['NightSceneAPI::IsActiveSceneActorPlayer;Int32'](i) then
            pcall(function()
                local actor = Game['NightSceneAPI::GetActiveSceneActor;Int32'](i)
                if actor then ExplicitSwap.Begin(actor) end
            end)
        end
    end

    -- Spawn V clone
    if hasPlayer then
        local recordID = getVCloneRecordID()
        print("[NightScene] Spawner: V clone: " .. recordID)

        local nakedMod = GetMod("NakedNPC")
        if nakedMod and nakedMod.UnequipPlayer then
            nakedMod.UnequipPlayer()
            WorkspotSpawner.playerWasUnequipped = true
            print("[NightScene] Spawner: Player unequipped for naked Clone V")
        end

        -- Hide the real V, in this order: the unequip above swaps V's outfit,
        -- which REBUILDS their mesh components -- hiding before it just gets
        -- undone. (Hiding first is exactly what failed: the counters showed 65
        -- components hidden and 0 slot items resolved, then the outfit change
        -- repopulated them and V stayed visible.)
        --
        -- HidePlayerForScene covers the gameplay side only (threat lists,
        -- movement lock); its SetInvisible is the optical-camo flag and does
        -- not stop V rendering. The mesh pass is what actually hides them.
        -- Gameplay side only (threat lists, movement lock). The visual hide is
        -- deliberately NOT done here: the clone is built from the player's
        -- current state, so hiding V's components first meant the clone came
        -- out without the Equipment-EX outfit. It runs once the clone exists.
        pcall(Game['NightSceneAPI::HidePlayerForScene;'])

        -- Ghost the player so the clone can't be shoved around by V's collision.
        pcall(function()
            local bump = Game.GetPlayer():GetBumpComponent()
            if bump then bump:Toggle(false) end
        end)
        print("[NightScene] Spawner: real V untargetable (visual hide follows clone spawn)")

        -- Don't spawn the clone in the same frame as the unequip. The clone is
        -- built from the player's CURRENT equipment state, and Equipment-EX's
        -- LoadOutfit doesn't apply instantly -- so spawning immediately races
        -- it and the clone can capture V still dressed. That race is why the
        -- nude outfit "sometimes" didn't take. Spawn is deferred a few frames
        -- in OnUpdate; the workspot entity streams in during the wait, so this
        -- usually costs no extra time at all.
        WorkspotSpawner.pendingCloneRecord = recordID
        -- 60 frames (~1s). Equipment-EX applies its outfit over an unknown
        -- number of frames and the clone is built from whatever the player
        -- looks like at spawn time, so too short a wait yields a clone wearing
        -- only part of the outfit. Raised from 20 while testing how much of
        -- the outfit actually transfers.
        WorkspotSpawner.pendingCloneDelay = 60
        print("[NightScene] Spawner: Clone V spawn deferred (waiting for outfit to apply)")
    end

    -- Spawn ONE shared workspot entity at actor 0's position
    local actor0 = Game['NightSceneAPI::GetActiveSceneActor;Int32'](0)
    if actor0 then
        local spawnTransform = actor0:GetWorldTransform()
        spawnTransform:SetPosition(actor0:GetWorldPosition())
        local angles = actor0:GetWorldOrientation():ToEulerAngles()
        angles.yaw = angles.yaw + 180.0
        spawnTransform:SetOrientationEuler(EulerAngles.new(0, 0, angles.yaw))

        WorkspotSpawner.workspotEntityID = exEntitySpawner.Spawn(entityPath, spawnTransform, '')
        print("[NightScene] Spawner: Spawning shared workspot")
    end

    WorkspotSpawner.pollTicks = 0
    WorkspotSpawner.polling = true
    return true
end

--- Play all actors in the ONE shared workspot entity.
--- Strip is handled in OnUpdate before PlayAll is called.
function WorkspotSpawner.PlayAll()
    local ok, err = pcall(function()
        local compName = Game['NightSceneAPI::GetActiveSceneWorkspotComp;']()
        local workspotSys = Game.GetWorkspotSystem()
        local wsEntity = WorkspotSpawner.workspotEntity

        for i = 0, WorkspotSpawner.actorCount - 1 do
            local isPlayer = Game['NightSceneAPI::IsActiveSceneActorPlayer;Int32'](i)
            local animNameStr = Game['NightSceneAPI::GetActiveSceneAnimNameStr;Int32'](i)
            local targetActor

            if isPlayer and WorkspotSpawner.vClone then
                targetActor = WorkspotSpawner.vClone
                print("[NightScene] Spawner: [" .. tostring(i) .. "] V CLONE -> '" .. (animNameStr or "?") .. "'")
            else
                local realActor = Game['NightSceneAPI::GetActiveSceneActor;Int32'](i)
                local standIn = ExplicitSwap.GetStandIn(realActor)

                if standIn then
                    -- The real NPC is hidden; their nude counterpart performs.
                    -- Deliberately NOT added to npcActorIDs: that list drives
                    -- the NakedNPC restore, which has nothing to undo here.
                    -- ExplicitSwap owns stopping and despawning stand-ins.
                    targetActor = standIn
                    print("[NightScene] Spawner: [" .. tostring(i) .. "] EXPLICIT -> '" .. (animNameStr or "?") .. "'")
                else
                    targetActor = realActor
                    print("[NightScene] Spawner: [" .. tostring(i) .. "] NPC -> '" .. (animNameStr or "?") .. "'")
                    -- Cache the entity ID now, while the scene is still active --
                    -- Cleanup() may run after the scene has already ended, at which
                    -- point NightSceneAPI can no longer look actors up by index.
                    if targetActor then
                        table.insert(WorkspotSpawner.npcActorIDs, targetActor:GetEntityID())
                    end
                end
            end

            if targetActor and animNameStr and animNameStr ~= "" then
                workspotSys:PlayInDeviceSimple(wsEntity, targetActor, false, compName, CName.new('AMM_WORKSPOT'), nil, 0, 1, nil)
                workspotSys:SendJumpToAnimEnt(targetActor, CName.new(animNameStr), true)
                print("[NightScene] Spawner: [" .. tostring(i) .. "] OK")
            end
        end

        if WorkspotSpawner.vClone then
            print("[NightScene] Spawner: Clone V stripped=" .. tostring(WorkspotSpawner.vCloneStripped or false))
        end
    end)

    if not ok then
        print("[NightScene] Spawner: PlayAll ERROR: " .. tostring(err))
    end
end

--- Re-point the actors already in the workspot at whatever clips the scene now
--- specifies, after the animation or stage changed. No respawn: the workspot
--- entity, the V clone and any explicit stand-ins all stay exactly as they are,
--- which is the whole point -- a teardown/rebuild would be visible as a hitch.
function WorkspotSpawner.SwitchAnimations()
    if not WorkspotSpawner.workspotEntity or WorkspotSpawner.polling then
        -- Still starting up. PlayAll hasn't run yet and will pick up the
        -- current clips when it does, so there's nothing to re-point.
        return false
    end

    local sys = Game.GetWorkspotSystem()

    for i = 0, WorkspotSpawner.actorCount - 1 do
        pcall(function()
            local isPlayer = Game['NightSceneAPI::IsActiveSceneActorPlayer;Int32'](i)
            local realActor = Game['NightSceneAPI::GetActiveSceneActor;Int32'](i)

            -- Same substitution PlayAll makes: clone for the player, explicit
            -- stand-in for a swapped NPC, otherwise the NPC itself.
            local actor
            if isPlayer then
                actor = WorkspotSpawner.vClone or realActor
            else
                actor = ExplicitSwap.GetStandIn(realActor) or realActor
            end

            local animNameStr = Game['NightSceneAPI::GetActiveSceneAnimNameStr;Int32'](i)
            if actor and animNameStr and animNameStr ~= "" then
                sys:SendJumpToAnimEnt(actor, CName.new(animNameStr), true)
                print("[NightScene] Spawner: [" .. tostring(i) .. "] switched -> '" .. animNameStr .. "'")
            end
        end)
    end

    return true
end

function WorkspotSpawner.Cleanup()
    WorkspotSpawner.polling = false
    local workspotSys = Game.GetWorkspotSystem()
    local nakedMod = GetMod("NakedNPC")

    -- Resolve NPC actors from the cached entity IDs (captured in PlayAll while
    -- the scene was still active) instead of querying NightSceneAPI by index --
    -- Cleanup() can run after the redscript scene has already ended (e.g. the
    -- auto-timeout path), at which point GetActiveScene()/GetSceneActor() and
    -- IsActiveSceneActorPlayer() all return null/false regardless of index.
    local npcActors = {}
    for _, eid in ipairs(WorkspotSpawner.npcActorIDs) do
        local actor = Game.FindEntityByID(eid)
        if actor then
            table.insert(npcActors, actor)
        end
    end

    -- Stop all actors FIRST so workspot releases the appearance system
    if WorkspotSpawner.vClone then
        pcall(function() workspotSys:StopInDevice(WorkspotSpawner.vClone) end)
    end
    for _, actor in ipairs(npcActors) do
        pcall(function() workspotSys:StopInDevice(actor) end)
    end
    for _, standIn in ipairs(ExplicitSwap.StandIns()) do
        pcall(function() workspotSys:StopInDevice(standIn) end)
    end

    -- NOW restore NPCs (workspot released, appearance system free)
    if nakedMod and nakedMod.RestoreFromScene then
        for _, actor in ipairs(npcActors) do
            pcall(function()
                nakedMod.RestoreFromScene(actor)
                print("[NightScene] Spawner: Restored actor")
            end)
        end
    end

    -- Despawn explicit stand-ins and unhide the NPCs they replaced. Done after
    -- StopInDevice so nothing is despawned mid-workspot.
    pcall(function() ExplicitSwap.RestoreAll() end)

    -- Put the real V's meshes back. Done before the re-equip below so the
    -- restored chunk masks apply to the body that's about to be re-dressed.
    local restored = WorkspotSpawner.ShowPlayer()
    print("[NightScene] Spawner: real V restored (" .. tostring(restored) .. " components)")
    pcall(function()
        local bump = Game.GetPlayer():GetBumpComponent()
        if bump then bump:Toggle(true) end
    end)

    -- Re-equip player clothing (was unequipped for Clone V naked spawn)
    if WorkspotSpawner.playerWasUnequipped then
        if nakedMod and nakedMod.ReequipPlayer then
            nakedMod.ReequipPlayer()
            print("[NightScene] Spawner: Player re-equipped")
        end
        WorkspotSpawner.playerWasUnequipped = nil
    end

    -- Despawn V clone
    if WorkspotSpawner.vClone then
        pcall(function() Game.GetDynamicEntitySystem():DeleteEntity(WorkspotSpawner.vCloneID) end)
        pcall(function() exEntitySpawner.Despawn(WorkspotSpawner.vClone) end)
        WorkspotSpawner.vClone = nil
        WorkspotSpawner.vCloneID = nil
        print("[NightScene] Spawner: V clone despawned")
    end

    -- Despawn workspot entity
    if WorkspotSpawner.workspotEntity then
        pcall(function() exEntitySpawner.Despawn(WorkspotSpawner.workspotEntity) end)
        WorkspotSpawner.workspotEntity = nil
        WorkspotSpawner.workspotEntityID = nil
    end

    -- Delay player restore to prevent air assassination on clone
    WorkspotSpawner.restorePending = true
    WorkspotSpawner.restoreDelay = 120
    print("[NightScene] Spawner: Player restore delayed 2s (prevent air assassination)")

    WorkspotSpawner.actorCount = 0
    WorkspotSpawner.readyTick = nil
    WorkspotSpawner.preStripped = nil
    WorkspotSpawner.vCloneStripped = nil
    WorkspotSpawner.playerWasUnequipped = nil
    WorkspotSpawner.pendingCloneDelay = nil
    WorkspotSpawner.pendingCloneRecord = nil
    WorkspotSpawner.npcActorIDs = {}

    -- The clone is gone, so chunk masks saved off it are meaningless now --
    -- keeping them would let a stale mask be restored onto the NEXT clone.
    cloneHeadSavedChunkMasks = {}


    print("[NightScene] Spawner: Cleaned up (player restore pending)")
end

return WorkspotSpawner