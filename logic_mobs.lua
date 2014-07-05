-- Creature settings - Mobs, logics:

-- This file contains the default AI functions for mobs. Advanced users can use a different AI instead of this, or execute additional code.

local DEBUG_AI_TARGETS = false
local highest_vision = 0

-- logic_mob_step: Executed in on_step, handles: animations, movement, attacking, damage, target management, decision making
function logic_mob_step (self, dtime)
	if self.attack_type and minetest.setting_getbool("only_peaceful_mobs") then
		self.object:remove()
	end

	-- remove this mob if its lifetime is up and doing so is appropriate
	self.timer_life = self.timer_life - dtime
	if self.timer_life <= 0 and not self.actor then
		local player_count = 0
		for _,obj in ipairs(minetest.env:get_objects_inside_radius(self.object:getpos(), 20)) do
			if obj:is_player() then
				player_count = player_count+1
			end
		end
		if player_count == 0 then
			self.object:remove()
			return
		else
			self.timer_life = 60
		end
	end

	-- physics: make mobs jump when they're stuck
	if self.jump and self.v_start and self.get_velocity(self) <= 1 and self.object:getvelocity().y == 0 then
		local v = self.object:getvelocity()
		v.y = self.jump_velocity
		self.object:setvelocity(v)
	end

	-- physics: make mobs push forward while jumping and apply gravity
	if self.object:getvelocity().y > 0.1 then
		local yaw = self.object:getyaw()
		local x = math.sin(yaw) * -2
		local z = math.cos(yaw) * 2
		self.object:setacceleration({x=x, y=-self.gravity, z=z})
	else
		self.object:setacceleration({x=0, y=-self.gravity, z=0})
	end

	-- physics: make mobs tend to stay at the water surface
	if self.in_liquid then
		local v = self.object:getvelocity()
		self.object:setacceleration({x=0, y=self.gravity/(math.max(1, v.y)^2), z=0})
	end

	-- handle fall damage
	if self.disable_fall_damage and self.object:getvelocity().y == 0 then
		if not self.old_y then
			self.old_y = self.object:getpos().y
		else
			local d = self.old_y - self.object:getpos().y
			if d > 5 then
				local damage = d-5
				self.object:set_hp(self.object:get_hp()-damage)
				if self.object:get_hp() == 0 then
					if self.sounds and self.sounds.die then
						minetest.sound_play(self.sounds.die, {object = self.object})
					end
					self.object:remove()
				else
					if self.sounds and self.sounds.damage then
						minetest.sound_play(self.sounds.damage, {object = self.object})
					end
				end
			end
			self.old_y = self.object:getpos().y
		end
	end

	-- handle environment damage
	self.timer_env_damage = self.timer_env_damage + dtime
	if self.timer_env_damage > 1 then
		self.timer_env_damage = 0
		local s = self.object:getpos()
		s.y = s.y - 1 -- exclude player offset
		local n = minetest.env:get_node(s)
		
		if self.env_damage.light and self.env_damage.light ~= 0
			and s.y>0
			and minetest.env:get_node_light(s)
			and minetest.env:get_node_light(s) > 4
			and minetest.env:get_timeofday() > 0.2
			and minetest.env:get_timeofday() < 0.8
		then
			self.object:set_hp(self.object:get_hp()-self.env_damage.light)
			if self.object:get_hp() == 0 then
				if self.sounds and self.sounds.die then
					minetest.sound_play(self.sounds.die, {object = self.object})
				end
				self.object:remove()
			else
				if self.sounds and self.sounds.damage then
					minetest.sound_play(self.sounds.damage, {object = self.object})
				end
			end
		end

		if self.env_damage.water and self.env_damage.water ~= 0 and
			minetest.get_item_group(n.name, "water") ~= 0
		then
			self.object:set_hp(self.object:get_hp()-self.env_damage.water)
			if self.object:get_hp() == 0 then
				if self.sounds and self.sounds.die then
					minetest.sound_play(self.sounds.die, {object = self.object})
				end
				self.object:remove()
			else
				if self.sounds and self.sounds.damage then
					minetest.sound_play(self.sounds.damage, {object = self.object})
				end

				-- jump if we're standing on something solid
				local v = self.object:getvelocity()
				if self.jump and v.y == 0 then
					v.y = self.jump_velocity
					self.object:setvelocity(v)
				end
			end
		end

		if self.env_damage.lava and self.env_damage.lava ~= 0 and
			minetest.get_item_group(n.name, "lava") ~= 0
		then
			self.object:set_hp(self.object:get_hp()-self.env_damage.lava)
			if self.object:get_hp() == 0 then
				if self.sounds and self.sounds.die then
					minetest.sound_play(self.sounds.die, {object = self.object})
				end
				self.object:remove()
			else
				if self.sounds and self.sounds.damage then
					minetest.sound_play(self.sounds.damage, {object = self.object})
				end
				
				-- jump if we're standing on something solid
				local v = self.object:getvelocity()
				if self.jump and v.y == 0 then
					v.y = self.jump_velocity
					self.object:setvelocity(v)
				end
			end
		end
	end

	self.timer_attack = self.timer_attack+dtime

	-- apply AI think speed, influenced by the mob's current status
	self.timer_think = self.timer_think+dtime
	if self.target_current and self.target_current.objective == "attack" then
		if self.timer_think < self.traits.think / 10 then
			return
		end
	elseif self.target_current and (self.target_current.objective == "follow" or self.target_current.objective == "avoid") then
		if self.timer_think < self.traits.think / 2 then
			return
		end
	else
		if self.timer_think < self.traits.think then
			return
		end
	end
	self.timer_think = 0

	-- determine if this mob is in a liquid
	local pos = self.object:getpos()
	local node = minetest.env:get_node(pos)
	local liquidtype = minetest.registered_nodes[node.name].liquidtype
	if (liquidtype == "source" or liquidtype == "flowing") then
		self.in_liquid = true
	else
		self.in_liquid = false
	end

	-- targets: scan for targets to add
	for _, obj in pairs(minetest.env:get_objects_inside_radius(self.object:getpos(), self.traits.vision)) do
		if obj ~= self.object and (obj:is_player() or (obj:get_luaentity() and obj:get_luaentity().traits)) and not self.targets[obj] then
			local s = self.object:getpos()
			local p = obj:getpos()
			local dist = ((p.x-s.x)^2 + (p.y-s.y)^2 + (p.z-s.z)^2)^0.5
			if dist < self.traits.vision then
				local relation = creatures:alliance(self.object, obj)
				local action = math.random()

				-- attack targets
				if self.attack_type and minetest.setting_getbool("enable_damage") and relation * self.traits.aggressivity <= -action then
					self.targets[obj] = {entity = obj, objective = "attack", priority = math.abs(relation) * self.traits.aggressivity}
				-- avoid targets
				elseif relation * self.traits.fear <= -action then
					self.targets[obj] = {entity = obj, objective = "avoid", priority = math.abs(relation) * self.traits.fear}
				-- follow targets
				elseif relation * self.traits.loyalty >= action then
					self.targets[obj] = {entity = obj, objective = "follow", priority = math.abs(relation) * self.traits.loyalty}
				end

				if DEBUG_AI_TARGETS and self.targets[obj] then
					local name2 = "creature"
					if obj:is_player() then
						name2 = obj:get_player_name()
					elseif obj:get_luaentity() then
						name2 = obj:get_luaentity().name
					end
					print("Creatures: "..self.name.." at "..math.floor(s.x)..","..math.floor(s.y)..","..math.floor(s.z)..
					" set "..name2.." at "..math.floor(p.x)..","..math.floor(p.y)..","..math.floor(p.z)..
					" as an \""..self.targets[obj].objective.."\" target with priority "..self.targets[obj].priority..
					" because self spotted the target")
				end
			end
		end
	end

	-- targets: select a random position to walk to when idle
	if self.traits.roam >= math.random() then
		local s = self.object:getpos()
		local p = {
			x = math.random(math.floor(s.x - self.traits.vision / 2), math.floor(s.x + self.traits.vision / 2)),
			y = math.floor(s.y),
			z = math.random(math.floor(s.z - self.traits.vision / 2), math.floor(s.z + self.traits.vision / 2)),
		}
		self.targets["idle"] = {position = p, objective = "follow", priority = 0}
	end

	-- targets: scan for targets to remove or modify
	for obj, target in pairs(self.targets) do
		if not target.persist then
			local target_old = target
			if target.position or (target.entity:is_player() or target.entity:get_luaentity()) then
				local s = self.object:getpos()
				local p = target.position or target.entity:getpos()
				local dist = ((p.x-s.x)^2 + (p.y-s.y)^2 + (p.z-s.z)^2)^0.5
				local dist_target = target.distance or self.traits.vision

				-- remove targets which are dead or out of range
				if dist > dist_target or (target.entity and target.entity:get_hp() <= 0) then
					self.targets[obj] = nil
				-- if the mob is no longer fit to fight, change attack targets to avoid
				elseif target.objective == "attack" and self.object:get_hp() <= self.hp_max * self.traits.fear then
					self.targets[obj].objective = "avoid"
				-- don't keep following mobs who have other business to attend to
				elseif target.objective == "follow" and target.entity and target.entity:get_luaentity() then
					local ent = target.entity:get_luaentity()
					if ent.target_current and ent.target_current.priority > 0 then
						self.targets[obj] = nil
					end
				end
			else
				-- remove players that disconnected or mobs that were removed from the world
				self.targets[obj] = nil
			end

			if DEBUG_AI_TARGETS then
				local s = self.object:getpos()
				local name2 = "creature"
				if target.entity:is_player() then
					name2 = target.entity:get_player_name()
				elseif target.entity:get_luaentity() then
					name2 = target.entity:get_luaentity().name
				end
				if not self.targets[obj] then
					print("Creatures: "..self.name.." at "..math.floor(s.x)..","..math.floor(s.y)..","..math.floor(s.z).." dropped "..name2..
					" because the target was no longer relevant")
				elseif self.targets[obj].objective ~= target_old.objective then
					print("Creatures: "..self.name.." at "..math.floor(s.x)..","..math.floor(s.y)..","..math.floor(s.z)..
					" switched "..name2.." from type "..target_old.objective.." to type \""..self.targets[obj].objective.."\"")
				end
			end
		end
	end

	-- targets: choose the most important target
	self.target_current = nil
	local best_priority = 0
	for i, target in pairs(self.targets) do
		local s = self.object:getpos()
		local p = target.position or target.entity:getpos()
		local dist = ((p.x-s.x)^2 + (p.y-s.y)^2 + (p.z-s.z)^2)^0.5
		local interest = (self.traits.vision * self.traits.determination) / dist

		-- an engine bug occasionally causes incorrect positions, so check that distance isn't 0
		if dist ~= 0 and target.priority * interest >= best_priority then
			best_priority = target.priority * interest
			self.target_current = target
		end
	end

	-- state: idle
	if not self.target_current then
		self.set_velocity(self, 0)
		self:set_animation("stand")
		self.v_start = false
	-- state: attacking, melee
	elseif self.target_current.objective == "attack" and self.attack_type == "melee" then
		local s = self.object:getpos()
		local p = self.target_current.position or self.target_current.entity:getpos()
		local dist = ((p.x-s.x)^2 + (p.y-s.y)^2 + (p.z-s.z)^2)^0.5
		local dist_target = self.target_current.distance or self.traits.vision

		local vec = {x=p.x-s.x, y=p.y-s.y, z=p.z-s.z}
		local yaw = math.atan(vec.z/vec.x)+math.pi/2
		if p.x > s.x then
			yaw = yaw+math.pi
		end
		self.object:setyaw(yaw)

		if dist > 2 and dist / dist_target >= 1 - self.target_current.priority then
			self.set_velocity(self, self.run_velocity)
			self:set_animation("walk_punch")
			self.v_start = true
		elseif dist > 2 then
			self.set_velocity(self, self.walk_velocity)
			self:set_animation("walk_punch")
			self.v_start = true
		else
			self.set_velocity(self, 0)
			self:set_animation("punch")
			self.v_start = false
			if self.timer_attack > self.traits.attack_interval then
				self.timer_attack = 0
				if self.sounds and self.sounds.attack then
					minetest.sound_play(self.sounds.attack, {object = self.object})
				end
				if self.target_current.entity then
					self.target_current.entity:punch(self.object, 1.0,  {
						full_punch_interval=1.0,
						damage_groups = {fleshy=self.attack_damage}
					}, vec)
				end
			end
		end

		if self.sounds and self.sounds.random_attack and math.random(1, 50) <= 1 then
			minetest.sound_play(self.sounds.random_attack, {object = self.object})
		end
	-- state: attacking, shoot
	elseif self.target_current.objective == "attack" and self.attack_type == "shoot" then
		local s = self.object:getpos()
		local p = self.target_current.position or self.target_current.entity:getpos()
		local vec = {x=p.x-s.x, y=p.y-s.y, z=p.z-s.z}
		local yaw = math.atan(vec.z/vec.x)+math.pi/2
		if p.x > s.x then
			yaw = yaw+math.pi
		end
		self.object:setyaw(yaw)
		self.set_velocity(self, 0)
		self:set_animation("punch")
		self.v_start = false

		if self.timer_attack > self.traits.attack_interval then
			self.timer_attack = 0
			if self.sounds and self.sounds.attack then
				minetest.sound_play(self.sounds.attack, {object = self.object})
			end

			s.y = s.y + (self.collisionbox[2]+self.collisionbox[5])/2
			local obj = minetest.env:add_entity(s, self.attack_arrow)
			local amount = (vec.x^2+vec.y^2+vec.z^2)^0.5
			local v = obj:get_luaentity().velocity
			vec.y = vec.y+1
			vec.x = vec.x*v/amount
			vec.y = vec.y*v/amount
			vec.z = vec.z*v/amount
			obj:setvelocity(vec)
		end

		if self.sounds and self.sounds.random_attack and math.random(1, 50) <= 1 then
			minetest.sound_play(self.sounds.random_attack, {object = self.object})
		end
	-- state: following or avoiding
	elseif self.target_current.objective == "follow" or self.target_current.objective == "avoid" then
		local avoid = self.target_current.objective == "avoid"

		local s = self.object:getpos()
		local p = self.target_current.position or self.target_current.entity:getpos()
		local dist = ((p.x-s.x)^2 + (p.y-s.y)^2 + (p.z-s.z)^2)^0.5
		local dist_target = self.target_current.distance or self.traits.vision

		local vec = {x=p.x-s.x, y=p.y-s.y, z=p.z-s.z}
		local yaw = math.atan(vec.z/vec.x)+math.pi/2
		if p.x > s.x then
			yaw = yaw+math.pi
		end
		if avoid then
			yaw = yaw+math.pi
		end
		self.object:setyaw(yaw)

		if (not avoid and dist / dist_target >= 1 - self.target_current.priority) or
		(avoid and dist / dist_target < 1 - self.target_current.priority) then
			self.set_velocity(self, self.run_velocity)
			self:set_animation("walk")
			self.v_start = true
		elseif dist > dist_target / 5 then
			self.set_velocity(self, self.walk_velocity)
			self:set_animation("walk")
			self.v_start = true
		else
			self.set_velocity(self, 0)
			self:set_animation("stand")
			self.v_start = false
		end

		if self.sounds and math.random(1, 50) <= 1 then
			if self.target_current.priority == 0 then
				if self.sounds.random_idle then
					minetest.sound_play(self.sounds.random_idle, {object = self.object})
				end
			elseif avoid and self.sounds.random_avoid then
				minetest.sound_play(self.sounds.random_avoid, {object = self.object})
			elseif not avoid and self.sounds.random_follow then
				minetest.sound_play(self.sounds.random_follow, {object = self.object})
			end
		end
	end
end

-- logic_mob_activate: Executed in on_activate, handles: initialization, static data management
function logic_mob_activate (self, staticdata, dtime_s)
	self.object:set_armor_groups({fleshy=self.armor})
	self.object:setacceleration({x=0, y=-10, z=0})
	self.object:setvelocity({x=0, y=self.object:getvelocity().y, z=0})
	self.object:setyaw(math.random(1, 360)/180*math.pi)
	if self.attack_type and minetest.setting_getbool("only_peaceful_mobs") then
		self.object:remove()
	end
	self.timer_life = 600 - dtime_s

	self.set_staticdata(self, staticdata, dtime_s)

	if self.timer_life <= 0 and not self.actor then
		self.object:remove()
	end

	-- set personality: each trait is a random value per mob, between the min and max values defined
	-- on_step must never execute before this is set, the code expects a single value for each trait!
	for trait, entry in pairs(self.traits) do
		if type(entry) == "table" then
			self.traits[trait] = math.random() * (entry[2] - entry[1]) + entry[1]
			-- some traits may only range between 0 and 1
			if trait == "roam" or trait == "loyalty" or trait == "fear" or trait == "aggressivity" or trait == "determination" then
				self.traits[trait] = math.min(1, math.max(0, self.traits[trait]))
			end
		end
	end

	-- if the textures field contains tables, we have multiple texture sets
	if self.textures and type(self.textures[1]) == "table" then
		if self.skin == 0 or not self.textures[self.skin] then
			self.skin = math.random(1, #self.textures)
		end
		self.object:set_properties({textures = self.textures[self.skin]})
	end

	-- we want to note what's the furthest distance a mob can see
	if self.traits.vision > highest_vision then
		highest_vision = self.traits.vision
	end
end

-- logic_mob_punch: Executed in on_punch, handles: damage, death, target management
function logic_mob_punch (self, hitter)
	local psettings = creatures.player_def[creatures:player_get(hitter)]
	local relation = creatures:alliance(self.object, hitter)

	-- trigger the player's attack sound
	if hitter:is_player() and psettings.sounds and psettings.sounds.attack then
		minetest.sound_play(psettings.sounds.attack, {object = hitter})
	end
	-- handle mob death
	if self.object:get_hp() <= 0 then
		if hitter and hitter:is_player() and hitter:get_inventory() then
			for _,drop in ipairs(self.drops) do
				if math.random(1, drop.chance) == 1 then
					hitter:get_inventory():add_item("main", ItemStack(drop.name.." "..math.random(drop.min, drop.max)))
				end
			end
		end
		if self.sounds and self.sounds.die then
			minetest.sound_play(self.sounds.die, {object = self.object})
		end
	-- targets: take action toward the creature who hit us
	else
		if not (self.targets[hitter] and self.targets[hitter].persist) and (hitter:is_player() or (hitter:get_luaentity() and hitter:get_luaentity().traits)) then
			local target_old = self.targets[hitter]
			local importance = (1 - relation) * 0.5
			local action = math.random()
			if self.attack_type and minetest.setting_getbool("enable_damage") and importance * self.traits.aggressivity >= action then
				if not self.targets[hitter] then
					self.targets[hitter] = {entity = hitter, objective = "attack", priority = importance * self.traits.aggressivity}
				else
					self.targets[hitter].objective = "attack"
					self.targets[hitter].priority = self.targets[hitter].priority + importance * self.traits.aggressivity
				end
			elseif importance * self.traits.fear >= action then
				if not self.targets[hitter] then
					self.targets[hitter] = {entity = hitter, objective = "avoid", priority = importance * self.traits.fear}
				else
					self.targets[hitter].objective = "aviod"
					self.targets[hitter].priority = self.targets[hitter].priority + importance * self.traits.fear
				end
			end

			if DEBUG_AI_TARGETS and self.targets[hitter] and (not target_old or self.targets[hitter].objective ~= target_old.objective) then
				local s = self.object:getpos()
				local p = hitter:getpos()
				local name2 = "hitter"
				if hitter:is_player() then
					name2 = hitter:get_player_name()
				elseif hitter:get_luaentity() then
					name2 = hitter:get_luaentity().name
				end
				print("Creatures: "..self.name.." at "..math.floor(s.x)..","..math.floor(s.y)..","..math.floor(s.z)..
				" set "..name2.." at "..math.floor(p.x)..","..math.floor(p.y)..","..math.floor(p.z)..
				" as an \""..self.targets[hitter].objective.."\" target with priority "..self.targets[hitter].priority..
				" because the target hit self")
			end
		end

		-- targets: make other mobs who see this mob fighting take action
		for _, obj in pairs(minetest.env:get_objects_inside_radius(self.object:getpos(), highest_vision)) do
			if obj ~= self.object and obj:get_luaentity() and obj:get_luaentity().traits then
				local other = obj:get_luaentity()
				local s = self.object:getpos()
				local p = obj:getpos()
				local h = hitter:getpos()
				local dist = ((p.x-s.x)^2 + (p.y-s.y)^2 + (p.z-s.z)^2)^0.5
				if dist ~= 0 and dist < other.traits.vision then
					local relation_other_self = creatures:alliance(obj, self.object)
					local relation_other_hitter = creatures:alliance(obj, hitter)
					-- determine who the bad guy is, and how important it is to interfere
					local relation_min = math.min(relation_other_hitter, relation_other_self)
					local relation_max = math.max(relation_other_hitter, relation_other_self)
					local importance = math.abs(relation_min - relation_max) * 0.5
					local action = math.random()
					local enemy = hitter
					if relation_other_self < relation_other_hitter then
						enemy = self.object
					end

					if not (other.targets[enemy] and other.targets[enemy].persist) then
						local target_old = other.targets[enemy]
						-- if we are loyal and eager enough to fight, attack our ally's enemy
						if other.attack_type and minetest.setting_getbool("enable_damage") and
						importance * ((other.traits.aggressivity + other.traits.loyalty) * 0.5) >= action then
							if not other.targets[enemy] then
								other.targets[enemy] = {entity = enemy, objective = "attack", priority = importance * ((other.traits.aggressivity + other.traits.loyalty) * 0.5)}
							else
								other.targets[enemy].objective = "attack"
								other.targets[enemy].priority = other.targets[enemy].priority + importance * ((other.traits.aggressivity + other.traits.loyalty) * 0.5)
							end
						-- if we are loyal but won't fight, follow our ally instead
						elseif importance * other.traits.loyalty >= action then
							if not other.targets[enemy] then
								other.targets[enemy] = {entity = enemy, objective = "follow", priority = importance * other.traits.loyalty}
							else
								other.targets[enemy].objective = "follow"
								other.targets[enemy].priority = other.targets[enemy].priority + importance * other.traits.loyalty
							end
						-- if we're afraid instead, avoid the side we're least comfortable with
						elseif importance * self.traits.fear >= action then
							if not other.targets[enemy] then
								other.targets[enemy] = {entity = enemy, objective = "avoid", priority = importance * self.traits.fear}
							else
								other.targets[enemy].objective = "avoid"
								other.targets[enemy].priority = other.targets[enemy].priority + importance * self.traits.fear
							end
						end

						if DEBUG_AI_TARGETS then
							local name2 = "witness"
							if hitter:is_player() then
								name2 = hitter:get_player_name()
							elseif hitter:get_luaentity() then
								name2 = hitter:get_luaentity().name
							end

							if self.targets[enemy] and (not target_old or self.targets[enemy].objective ~= target_old.objective) then
								print("Creatures: "..self.name.." at "..math.floor(s.x)..","..math.floor(s.y)..","..math.floor(s.z)..
								" and "..name2.." at "..math.floor(h.x)..","..math.floor(h.y)..","..math.floor(h.z)..
								" caused "..other.name.." at "..math.floor(p.x)..","..math.floor(p.y)..","..math.floor(p.z)..
								" to set hitter or self as an \""..other.targets[enemy].objective.."\" target with priority "..other.targets[enemy].priority)
							end
						end
					end
				end
			end
		end

		if self.sounds and self.sounds.damage then
			minetest.sound_play(self.sounds.damage, {object = self.object})
		end
	end
end

-- logic_mob_rightclick: Executed in on_rightclick, handles: possession
function logic_mob_rightclick (self, clicker)
	local psettings = creatures.player_def[creatures:player_get(clicker)]
	if not self.actor and clicker:is_player() and psettings.reincarnate and self.target_current and clicker == self.target_current.entity then
		clicker:setpos(self.object:getpos())
		clicker:set_look_yaw(self.object:getyaw())
		clicker:set_look_pitch(0)
		creatures:player_set(clicker, {name = self.name, skin = self.skin, hp = self.object:get_hp()})
		self.object:remove()
	end
end