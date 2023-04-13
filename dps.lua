---@class DPS
---@field config Config
---@field fFatigueBase number
---@field fFatigueMult number
---@field fCombatInvisoMult number
---@field fSwingBlockBase number
---@field fSwingBlockMult number
---@field fBlockStillBonus number
---@field iBlockMinChance number
---@field iBlockMaxChance number
---@field fCombatArmorMinMult number
---@field fDifficultyMult number
---@field fDamageStrengthBase number
---@field fDamageStrengthMult number
---@field restoreDrainAttributesFix boolean
---@field blindFix integer
---@field rangedWeaponCanCastOnSTrike boolean
---@field throwWeaponAlreadyModified boolean
---@field poisonCrafting PoisonCrafting
local DPS = {}

---@param cfg Config?
---@return DPS
function DPS.new(cfg)
    local dps = {
        config = cfg and cfg or require("longod.DPSTooltips.config").Load()
    }
    setmetatable(dps, { __index = DPS })
    return dps
end

local logger = require("longod.DPSTooltips.logger")
local combat = require("longod.DPSTooltips.combat")
local resolver = require("longod.DPSTooltips.effect")

---@param self DPS
function DPS.Initialize(self)
    ---@diagnostic disable: need-check-nil
    -- TODO @cast if possible
    ---@diagnostic disable: assign-type-mismatch
    self.fFatigueBase = tes3.findGMST(tes3.gmst.fFatigueBase).value
    self.fFatigueMult = tes3.findGMST(tes3.gmst.fFatigueMult).value
    self.fCombatInvisoMult = tes3.findGMST(tes3.gmst.fCombatInvisoMult).value
    self.fSwingBlockBase = tes3.findGMST(tes3.gmst.fSwingBlockBase).value
    self.fSwingBlockMult = tes3.findGMST(tes3.gmst.fSwingBlockMult).value
    self.fBlockStillBonus = 1.25 -- tes3.findGMST(tes3.gmst.fBlockStillBonus).value -- hardcoded, OpenMW uses gmst
    self.iBlockMinChance = tes3.findGMST(tes3.gmst.iBlockMinChance).value
    self.iBlockMaxChance = tes3.findGMST(tes3.gmst.iBlockMaxChance).value
    self.fCombatArmorMinMult = tes3.findGMST(tes3.gmst.fCombatArmorMinMult).value
    self.fDifficultyMult = tes3.findGMST(tes3.gmst.fDifficultyMult).value

    -- resolve MCP or mod
    self.fDamageStrengthBase = 0.5
    self.fDamageStrengthMult = 0.01
    -- This MCP feature causes the game to use these GMSTs in its weapon damage calculations instead of the hardcoded
    -- values used by the vanilla game. With default values for the GMSTs the outcome is the same.
    if tes3.hasCodePatchFeature(tes3.codePatchFeature.gameFormulaRestoration) then
        -- maybe require restart when to get initialing
        logger:info("Enabled MCP GameFormulaRestoration")
        self.fDamageStrengthBase = tes3.findGMST(tes3.gmst.fDamageStrengthBase).value
        self.fDamageStrengthMult = 0.1 * tes3.findGMST(tes3.gmst.fDamageStrengthMult).value
    end

    self.restoreDrainAttributesFix = false
    if tes3.hasCodePatchFeature(tes3.codePatchFeature.restoreDrainAttributesFix) then
        logger:info("Enabled MCP RestoreDrainAttributesFix")
        self.restoreDrainAttributesFix = true
    end

    -- sign
    self.blindFix = -1
    if tes3.hasCodePatchFeature(tes3.codePatchFeature.blindFix) then
        logger:info("Enabled MCP BlindFix")
        self.blindFix = 1
    end

    -- https://www.nexusmods.com/morrowind/mods/45913
    self.rangedWeaponCanCastOnSTrike = false
    if tes3.isModActive("Cast on Strike Bows.esp") then
        -- this MCP fix seems, deny on strile option when enchaning, exsisting ranged weapons on strike dont require this fix to torigger.
        -- ~tes3.hasCodePatchFeature(tes3.codePatchFeature.fixEnchantOptionsOnRanged)
        logger:info("Enabled Cast on Strike Bows")
        self.rangedWeaponCanCastOnSTrike = true
    end

    -- https://www.nexusmods.com/morrowind/mods/49609
    -- The vanilla game doubles the official damage values for thrown weapons. The mod Thrown Projectiles Revamped
    -- halves the actual damage done, so don't double the displayed damage if that mod is in use.
    self.throwWeaponAlreadyModified = false
    if tes3.isLuaModActive("DQ.ThroProjRev") then
        logger:info("Enabled Thrown Projectiles Revamped")
        self.throwWeaponAlreadyModified = true
    end

    self.poisonCrafting = nil
    if tes3.isLuaModActive("poisonCrafting") then
        logger:info("Enabled Poison Crafting")
        self.poisonCrafting = require("longod.DPSTooltips.poison")
    end
end

---@param self DPS
---@param weapon tes3weapon
---@return boolean
function DPS.CanCastOnStrike(self, weapon)
    return self.rangedWeaponCanCastOnSTrike or weapon.isRanged == false
end

-- combination effect id, attribute, skill
---@param effect tes3.effect
---@param attribute tes3.attribute?
---@param skill tes3.skill?
---@return integer
local function GenerateKey(effect, attribute, skill)
    local b = require("bit")
    local key = 0
    if effect ~= nil and effect >= 0 then
        key = effect
        logger:debug(string.format("%d", effect))
    end
    if attribute and attribute >= 0 then
        key = b.bor(b.lshift(attribute, 16), key)
        logger:debug(string.format("%d", attribute))
    end
    if skill and skill >= 0 then
        key = b.bor(b.lshift(skill, 16 + 4), key)
        logger:debug(string.format("%d", skill))
    end
    return key
end

---@param data ScratchData
---@param icons { [tes3.effect]: string[] }
---@param effects tes3effect[]
---@param weaponSpeed number
---@param weaponSkillId tes3.skill
---@param forceTargetEffects boolean
---@return ScratchData
---@return { [tes3.effect]: string[] }
local function CollectEffects(data, icons, effects, weaponSpeed, weaponSkillId, forceTargetEffects)
    for _, effect in ipairs(effects) do
        if effect ~= nil and effect.id >= 0 then
            local id = effect.id
            local r = resolver.Get(id)
            if r then
                local value = (effect.max + effect.min) * 0.5 -- uniform RNG average
                local isSelf = effect.rangeType == tes3.effectRange.self
                if forceTargetEffects then
                    isSelf = false
                end
                ---@type Params
                local params = {
                    data = data,
                    key = id,
                    value = value,
                    speed = weaponSpeed,
                    isSelf = isSelf,
                    attacker = r.attacker,
                    target = r.target,
                    attribute = effect.attribute, -- if invalid it returns -1. not nil.
                    skill = effect.skill,         -- if invalid it returns -1. not nil.
                    weaponSkillId = weaponSkillId,
                }
                local affect = r.func(params)
                if affect and id ~= nil then
                    -- adding own key, then merge on resolve phase
                    if not icons[id] then
                        icons[id] = {}
                    end
                    table.insert(icons[id], effect.object.icon)
                end
            end
        end
    end
    return data, icons
end

---@param enchantment tes3enchantment
---@param weaponSpeed number
---@param canCastOnStrike boolean
---@param weaponSkillId tes3.skill
---@return ScratchData
---@return { [tes3.effect]: string[] }
local function CollectEnchantmentEffect(enchantment, weaponSpeed, canCastOnStrike, weaponSkillId)
    local data = resolver.CreateScratchData()

    local icons = {} ---@type {[tes3.effect]: string[]}

    if enchantment then
        -- todo not yet on cast
        -- better is on strike effect consider charge cost
        local onStrike = canCastOnStrike and enchantment.castType == tes3.enchantmentType.onStrike
        local constant = enchantment.castType == tes3.enchantmentType.constant
        if onStrike or constant then
            CollectEffects(data, icons, enchantment.effects, weaponSpeed, weaponSkillId, false)
        end
    end

    return data, icons
end

---@param self DPS
---@param agility number
---@param luck number
---@param fatigueTerm number
---@param sanctuary number
---@param chameleon number
---@param invisibility boolean
---@param isKnockedDown boolean
---@param isParalyzed boolean
---@param unware boolean
---@return number
function DPS.CalculateEvasion(self, agility, luck, fatigueTerm, sanctuary, chameleon, invisibility, isKnockedDown,
                              isParalyzed, unware)
    local evasion = 0
    if not (isKnockedDown or isParalyzed or unware) then
        evasion = combat.CalculateEvasion(agility, luck, fatigueTerm, sanctuary)
    end
    evasion = evasion + math.min(self.fCombatInvisoMult * chameleon, 100)
    evasion = evasion + math.min(self.fCombatInvisoMult * (invisibility and 1 or 0), 100)
    return evasion
end

-- from Accurate Tooltip Stats (https://www.nexusmods.com/morrowind/mods/51354) by Necrolesian
---@param weapon tes3weapon
---@param itemData tes3itemData
---@return number
local function GetConditionModifier(weapon, itemData)
    -- Projectiles (thrown weapons, arrows, bolts) have no condition data.
    local hasDurability = weapon.hasDurability
    local maximumCondition = (hasDurability and weapon.maxCondition) or 1.0
    local currentCondition = (hasDurability and itemData and itemData.condition) or maximumCondition
    return currentCondition / maximumCondition
end

-- from Accurate Tooltip Stats (https://www.nexusmods.com/morrowind/mods/51354) by Necrolesian
---@param self DPS
---@param strength number
---@return number
function DPS.GetStrengthModifier(self, strength)
    -- how capped value without mcp patch?
    local currentStrength = math.max(strength, 0)
    -- resolved base and mult on initialize
    return self.fDamageStrengthBase + (self.fDamageStrengthMult * currentStrength)
end

---@class DamageRange
---@field min number
---@field max number

-- from Accurate Tooltip Stats (https://www.nexusmods.com/morrowind/mods/51354) by Necrolesian
---@param self DPS
---@param weapon tes3weapon
---@param marksman boolean
---@return { [tes3.physicalAttackType]: DamageRange }
function DPS.GetWeaponBaseDamage(self, weapon, marksman)
    local baseDamage = {} ---@type { [tes3.physicalAttackType]: DamageRange }
    if marksman then
        baseDamage[tes3.physicalAttackType.projectile] = { min = weapon.chopMin, max = weapon.chopMax }
    else
        baseDamage[tes3.physicalAttackType.slash] = { min = weapon.slashMin, max = weapon.slashMax }
        baseDamage[tes3.physicalAttackType.thrust] = { min = weapon.thrustMin, max = weapon.thrustMax }
        baseDamage[tes3.physicalAttackType.chop] = { min = weapon.chopMin, max = weapon.chopMax }
    end

    -- The vanilla game doubles the official damage values for thrown weapons. The mod Thrown Projectiles Revamped
    -- halves the actual damage done, so don't double the displayed damage if that mod is in use.
    if weapon.type == tes3.weaponType.marksmanThrown and not self.throwWeaponAlreadyModified then
        baseDamage[tes3.physicalAttackType.projectile].min = 2 * baseDamage[tes3.physicalAttackType.projectile].min
        baseDamage[tes3.physicalAttackType.projectile].max = 2 * baseDamage[tes3.physicalAttackType.projectile].max
    end

    return baseDamage
end

---@param self DPS
---@param currentFatigue number
---@param baseFatigue number
---@return number
function DPS.GetFatigueTerm(self, currentFatigue, baseFatigue)
    return math.max(self.fFatigueBase - self.fFatigueMult * math.max(1.0 - currentFatigue / baseFatigue, 0.0), 0.0)
end

---@param self DPS
---@param weapon tes3weapon
---@param itemData tes3itemData
---@param speed number
---@param strength number
---@param armorRating number
---@param marksman boolean
---@return { [tes3.physicalAttackType]: DamageRange }
function DPS.CalculateWeaponDamage(self, weapon, itemData, speed, strength, armorRating, marksman)
    local baseDamage = self:GetWeaponBaseDamage(weapon, marksman)
    local damageMultStr = 0
    local damageMultCond = 1.0
    if self.config.accurateDamage then
        damageMultStr = self:GetStrengthModifier(strength)
        if not self.config.maxDurability then
            damageMultCond = GetConditionModifier(weapon, itemData)
        end
    end
    local minSpeed = speed -- TODO maybe more quickly, it seems depends animation frame
    local maxSpeed = speed -- same as animation frame?
    for _, v in pairs(baseDamage) do
        if self.config.accurateDamage then
            v.min = combat.CalculateAcculateWeaponDamage(v.min, damageMultStr, damageMultCond, 1);
            v.max = combat.CalculateAcculateWeaponDamage(v.max, damageMultStr, damageMultCond, 1);

            -- The reduction occurs only after all the multipliers are applied to the damage.
            if armorRating > 0 then
                v.min = combat.CalculateDamageReductionFromArmorRating(v.min, armorRating, self.fCombatArmorMinMult)
                v.max = combat.CalculateDamageReductionFromArmorRating(v.max, armorRating, self.fCombatArmorMinMult)
            end
        end
        v.min = combat.CalculateDPS(v.min, minSpeed)
        v.max = combat.CalculateDPS(v.max, maxSpeed)
    end
    return baseDamage
end

-- TODO rename
-- TODO useBestAttack timing is too late, should be base damage phase. but results almost same
---@param weaponDamages { [tes3.physicalAttackType]: DamageRange }
---@param minmaxRange boolean
---@param useBestAttack boolean
---@return DamageRange
---@return { [tes3.physicalAttackType] :boolean }
local function ResolveWeaponDPS(weaponDamages, minmaxRange, useBestAttack)
    local damageRange = { min = 0, max = 0 } ---@type DamageRange
    local highestType = {}
    local typeDamages = {}
    local highest = 0
    for k, v in pairs(weaponDamages) do
        damageRange.min = math.max(damageRange.min, v.min)
        damageRange.max = math.max(damageRange.max, v.max)
        local typeDamage = v.max
        if minmaxRange or useBestAttack then
            typeDamage = (v.max + v.min) -- average
        end
        highest = math.max(highest, typeDamage)
        typeDamages[k] = typeDamage
    end
    for k, v in pairs(typeDamages) do
        if highest == v then -- lua can compare float equals?
            highestType[k] = true
        end
    end
    return damageRange, highestType
end

---@param icons { [tes3.effect]: string[] }
---@param dest tes3.effect
---@param src tes3.effect
local function MergeIcons(icons, dest, src)
    if dest ~= src and icons[src] then
        if not icons[dest] then
            icons[dest] = {}
        end
        for _, path in ipairs(icons[src]) do
            table.insert(icons[dest], path)
        end
    end
end

---@param effect ScratchData
---@return number
---@return {[tes3.effect]: number}
local function ResolveEffectDPS(effect)
    local effectDamages = {}
    local effectTotal = 0

    -- damage
    for k, v in pairs(effect.target.damages) do
        effectDamages[k] = v
        effectTotal = effectTotal + v
    end

    -- healing
    local healing = {
        tes3.effect.restoreHealth,
        tes3.effect.fortifyHealth,
    }
    for _, v in ipairs(healing) do
        local h          = resolver.GetValue(effect.target.positives, v, 0)
        effectDamages[v] = -h -- display value is negative
        effectTotal      = effectTotal - h
    end

    return effectTotal, effectDamages
end

---@param effect ScratchData
---@param icons { [tes3.effect]: string[] }
---@param resistMagicka number
local function ResolveModifiers(effect, icons, resistMagicka)
    -- effect.target.resists = {}
    -- effect.attacker.resists = {}
    -- resist/weakness magicka
    local rm = tes3.effect.resistMagicka
    local wm = tes3.effect.weaknesstoMagicka
    -- Once Resist Magicka reaches 100%, it's the only type of resistance that can't be broken by a Weakness effect, since Weakness is itself a magicka type spell.
    -- so if both apply, above works?
    local targetResistMagicka = combat.InverseNormalizeMagnitude(resolver.GetValue(effect.target.positives, rm, 0))
    targetResistMagicka = combat.InverseNormalizeMagnitude(resolver.GetValue(effect.target.negatives, wm, 0)) *
    targetResistMagicka
    local attackerResistMagicka = combat.InverseNormalizeMagnitude(resolver.GetValue(effect.attacker.positives, rm, 0) +
    resistMagicka)
    attackerResistMagicka = combat.InverseNormalizeMagnitude(resolver.GetValue(effect.attacker.negatives, wm, 0)) *
    attackerResistMagicka
    effect.target.resists[rm] = targetResistMagicka
    effect.attacker.resists[rm] = attackerResistMagicka
    -- apply resist magicka to negative effects
    -- TODO use acculate option? or remove opiton
    for k, v in pairs(effect.target.negatives) do
        if k ~= tes3.effect.weaknesstoMagicka then
            effect.target.negatives[k] = v * targetResistMagicka
        end
    end
    for k, v in pairs(effect.attacker.negatives) do
        if k ~= tes3.effect.weaknesstoMagicka then
            effect.attacker.negatives[k] = v * attackerResistMagicka
        end
    end

    -- probability
    -- but it seems not apply the same item effects. if effects already applied, it can be dispeled.
    -- local reflectChance = resolver.GetValue(effect.target.positives, tes3.effect.spellAbsorption, 1.0) *
    --     resolver.GetValue(effect.target.positives, tes3.effect.reflect, 1.0)
    -- local dispelChance = InverseNormalizeMagnitude(resolver.GetValue(effect.target.positives, tes3.effect.dispel, 0))

    -- merge resist/weakness elemental and shield
    local resistweakness = {
        [tes3.effect.resistFire]          = { tes3.effect.weaknesstoFire, tes3.effect.fireShield },
        [tes3.effect.resistFrost]         = { tes3.effect.weaknesstoFrost, tes3.effect.frostShield },
        [tes3.effect.resistShock]         = { tes3.effect.weaknesstoShock, tes3.effect.lightningShield },
        -- [tes3.effect.resistMagicka]       = {tes3.effect.weaknesstoMagicka}, -- pre calculated
        [tes3.effect.resistPoison]        = { tes3.effect.weaknesstoPoison },
        [tes3.effect.resistNormalWeapons] = { tes3.effect.weaknesstoNormalWeapons },
    }
    for k, v in pairs(resistweakness) do
        local resist = resolver.GetValue(effect.target.positives, k, 0)
        if v[2] then -- shield
            resist = resist + resolver.GetValue(effect.target.positives, v[2], 0)
            MergeIcons(icons, k, v[2])
        end
        resist = resist - resolver.GetValue(effect.target.negatives, v[1], 0)
        effect.target.resists[k] = combat.InverseNormalizeMagnitude(resist)

        MergeIcons(icons, k, v[1])
    end

    -- negative attrib, skill
    ---@param modifiers AttributeModifier|SkillModifier
    ---@param mod number
    local function ApplyResistMagicka(modifiers, mod)
        for k, v in pairs(modifiers.damage) do
            modifiers.damage[k] = v * mod
        end
        for k, v in pairs(modifiers.drain) do
            modifiers.drain[k] = v * mod
        end
        for k, v in pairs(modifiers.absorb) do
            modifiers.absorb[k] = v * mod
        end
    end
    ApplyResistMagicka(effect.target.attributes, targetResistMagicka)
    ApplyResistMagicka(effect.target.skills, targetResistMagicka)
    ApplyResistMagicka(effect.attacker.attributes, attackerResistMagicka)
    ApplyResistMagicka(effect.attacker.skills, attackerResistMagicka)
    -- absorb values from target to attacker
    for k, v in pairs(effect.target.attributes.absorb) do
        effect.attacker.attributes.absorb[k] = -v -- invert for GetModified
    end
    for k, v in pairs(effect.target.skills.absorb) do
        effect.attacker.skills.absorb[k] = -v -- invert for GetModified
    end

    -- damage
    local e = effect.target
    local pair = {
        [tes3.effect.fireDamage] = tes3.effect.resistFire,
        [tes3.effect.frostDamage] = tes3.effect.resistFrost,
        [tes3.effect.shockDamage] = tes3.effect.resistShock,
        [tes3.effect.poison] = tes3.effect.resistPoison,
        [tes3.effect.absorbHealth] = tes3.effect.resistMagicka,
        [tes3.effect.damageHealth] = tes3.effect.resistMagicka,
        [tes3.effect.drainHealth] = tes3.effect.resistMagicka, -- temporary down
        [tes3.effect.sunDamage] = nil,                         -- only vampire
    }

    for k, v in pairs(pair) do
        if v then
            local damage = resolver.GetValue(e.damages, k, 0) * resolver.GetValue(e.resists, v, 1.0)
            e.damages[k] = damage
            MergeIcons(icons, k, v)
        end
    end

    -- cure poison
    if resolver.GetValue(e.positives, tes3.effect.curePoison, 0) > 0 and e.damages[tes3.effect.poison] then
        e.damages[tes3.effect.poison] = 0
        MergeIcons(icons, tes3.effect.poison, tes3.effect.curePoison)
    end
end

---@param e Modifier
---@param t tes3.attribute
---@param attributes tes3statistic[]
---@return number
local function GetModifiedAttribute(e, t, attributes)
    local current = attributes[t + 1].current
    if e.attributes.damage[t] then
        current = current - e.attributes.damage[t]
    end

    -- TODO mcp fix or unfix
    -- if your Strength has been damaged 25 points, but you're wearing the Right Fist of Randagulf (+20 Fortify), Restore Strength would only give you back 5 points. To get around this, remove the Fortify effect (in the above example, remove the gauntlet) before invoking the Restore effect.
    -- This bug is fixed by the Morrowind Code Patch.

    -- Restore attributes spells did not recognise Fortify effects when restoring. Take for example, a base agility of 50, fortified by +30 to 80. If your agility was damaged below 80, a Restore spell would only restore up to 50 and stop working. Restore attributes spells now restore up to your fully fortified amount.
    -- The same problem occurred when Drain attributes spells expired. These should now restore the fortified attribute properly as well.

    if e.attributes.restore[t] then -- can restore drained value?
        local base = attributes[t + 1].base
        local decreased = math.max(base - current, 0)
        current = current + math.min(e.attributes.restore[t], decreased)
    end
    if e.attributes.drain[t] then
        current = current - e.attributes.drain[t] -- at once
    end
    if e.attributes.fortify[t] then
        current = current + e.attributes.fortify[t]
    end
    if e.attributes.absorb[t] then
        current = current - e.attributes.absorb[t] -- HACK attacker's sign must be negative
    end
    return current
end

---@param e Modifier
---@param t tes3.skill
---@param skills tes3statisticSkill[]
---@return number
local function GetModifiedSkill(e, t, skills)
    local current = skills[t + 1].current
    if e.skills.damage[t] then
        current = current - e.skills.damage[t]
    end
    -- TODO mcp fix or unfix

    if e.skills.restore[t] then -- can restore drained value?
        local base = skills[t + 1].base
        local decreased = math.max(base - current, 0)
        current = current + math.min(e.skills.restore[t], 0)
    end
    if e.skills.drain[t] then
        current = current - e.skills.drain[t] -- at once
    end
    if e.skills.fortify[t] then
        current = current + e.skills.fortify[t]
    end
    if e.skills.absorb[t] then
        current = current - e.skills.absorb[t] -- HACK attacker's sign must be negative
    end
    return current
end

---@param effect ScratchData
local function GetTargetArmorRating(effect)
    local shield = resolver.GetValue(effect.target.positives, tes3.effect.shield, 0);
    return shield -- currently only shield effect
end

-- local function GetModifiedCurrentFatigue(e, t, fatigue)
-- end
-- local function GetModifiedMaxFatigue(e, t, fatigue)
-- end

-- local function CalculateHitRate_(weapon, effect)
--     local skillId = weapon.skillId
--     local weaponSkill = math.max(tes3.mobilePlayer:getSkillValue(skillId) + GetModifiedSkill(effect.attacker, skillId), 0)
--     local agility = math.max(
--         tes3.mobilePlayer.agility.current + GetModifiedAttribute(effect.attacker, tes3.attribute.agility), 0)
--     local luck = math.max(tes3.mobilePlayer.luck.current + GetModifiedAttribute(effect.attacker, tes3.attribute.luck), 0)
--     -- return CalculateHitRate(weaponSkill, agility, luck, 0, 1, 0, 0)
-- end

-- local function CalculateEvasion_(weapon, effect)
-- end

-- local function CalculateHit(weapon, effect)
--     --return CalculateChanceToHit(hitRate, evasion)
-- end


---@class DPSData
---@field weaponDamageRange table
---@field weaponDamages table
---@field highestType { [tes3.physicalAttackType]: boolean }
---@field effectTotal number
---@field effectDamages { [tes3.effect]: number }
---@field icons { [tes3.effect]: string[] }

-- I'm not sure how to resolve Morrowind's effect strictly.
-- If it was to apply them in order from the top, each time, then when the order is Damage, Weakness, so Weakness would have no effect at all.
-- It is indeed possible to do so, but here it resolves all modifiers once and then apply them.
-- And Why do I not use tes3.getEffectMagnitude() or other useful functions? That's because it works for players, but cannot be used against a notional, nonexistent enemy.
---@param self DPS
---@param weapon tes3weapon
---@param itemData tes3itemData
---@param useBestAttack boolean
---@return DPSData
function DPS.CalculateDPS(self, weapon, itemData, useBestAttack)
    local marksman = weapon.isRanged or weapon.isProjectile
    local speed = weapon.speed -- TODO perhaps speed is scale factor, not acutal length

    local effect, icons = CollectEnchantmentEffect(weapon.enchantment, speed, self:CanCastOnStrike(weapon),
        weapon.skillId)

    if self.poisonCrafting then
        local poison = self.poisonCrafting.GetPoison(weapon, itemData)
        if poison then
            -- poison effect is only once, so speed is 1
            -- Also in vanilla, potion's effectRange is always self, because of it cannot be applied to weapons. Therefore, it is forced to be touch effect
            CollectEffects(effect, icons, poison.effects, 1, weapon.skillId, true)
        end
    end

    -- TODO this resist magicka should ignore applied effect from this weapon
    local resistMagicka = tes3.mobilePlayer.resistMagicka
    ResolveModifiers(effect, icons, resistMagicka)

    -- experimental: counter applied active magic effect
    -- TODO before resolve for resistMagicka
    -- split writing destination, values shoud not resist, they are resisted already.
    if weapon.enchantment then
        local onStrike = self:CanCastOnStrike(weapon) and weapon.enchantment.castType == tes3.enchantmentType.onStrike
        local constant = weapon.enchantment.castType == tes3.enchantmentType.constant
        if onStrike or constant then -- no on use
            for _, a in ipairs(tes3.mobilePlayer.activeMagicEffectList) do
                if a.instance.sourceType == tes3.magicSourceType.enchantment and
                    a.instance.item and a.instance.item.objectType == tes3.objectType.weapon then
                    -- only tooltip weapon, possible enemy attacked using same weapon.
                    if a.instance.item.id == weapon.id and a.instance.magicID == weapon.enchantment.id and a.effectId >= 0 then
                        logger:debug(weapon.id .. " " .. weapon.enchantment.id)
                        local id = a.effectId
                        local r = resolver.Get(id)
                        if r then
                            ---@type Params
                            local params = {
                                data = effect,
                                key = id,
                                value = -a.effectInstance.effectiveMagnitude, -- counter resisted value
                                speed = 1.0,
                                isSelf = true,
                                attacker = r.attacker,
                                target = r.target,
                                attribute = a.attributeId,
                                skill = a.skillId,
                                weaponSkillId = weapon.skillId,
                            }
                            -- TODO use original function, but reusing almost case is ok
                            r.func(params)
                        end
                    end
                end
            end
        end
    end

    -- TODO icons
    local strength = GetModifiedAttribute(effect.attacker, tes3.attribute.strength, tes3.mobilePlayer.attributes)
    local armorRating = GetTargetArmorRating(effect);

    local weaponDamages = self:CalculateWeaponDamage(weapon, itemData, speed, strength, armorRating, marksman)
    local weaponDamageRange, highestType = ResolveWeaponDPS(weaponDamages, self.config.minmaxRange, useBestAttack)
    local effectTotal, effectDamages = ResolveEffectDPS(effect)

    return {
        weaponDamageRange = weaponDamageRange,
        weaponDamages = weaponDamages,
        highestType = highestType,
        effectTotal = effectTotal,
        effectDamages = effectDamages,
        icons = icons,
    }
end

return DPS
