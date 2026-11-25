--!strict
--[[
	=== Collectors.Community ===================================================

	Group status and the group-bonus flag (plan H4 / H14, spec 05-social:02).

	WHICH GROUP (config Group, or HarvestService.SetGroup at runtime)

	    { Mode = "GameOwner" }        the group that owns the experience
	                                  (game.CreatorType == Group -> CreatorId).
	                                  A user-owned game has no owner group:
	                                  status "unavailable".
	    { Mode = "Id", GroupId = n }  that group
	    { Mode = "Off" }              no checks; status "off"

	STATUS IS A STRING, never a boolean, so unknown cannot pass for false:

	    "true"         verified member (Player:IsInGroupAsync)
	    "false"        verified non-member
	    "unknown"      not checked yet, or every attempt failed this session
	    "unavailable"  no group to check (user-owned game in GameOwner mode)
	    "off"          group features turned off

	One check per player per session, at ready; a failure is retried on the
	next ticks up to Tunables.GroupCheckAttempts. Roblox caches the answer
	per server, so a player who joins the group mid-session is seen on their
	next session (H0). EverGroupMember is sticky for the same GroupId. If the
	configured group CHANGES, the membership fields are reset (they described
	another group); the bonus flag is kept.

	GROUP BONUS. Harvest never grants anything. The game grants its bonus,
	then reports it: Emit(player, "group_bonus_claimed", { ClaimId = ... },
	"groupbonus:" .. player.UserId). The FIRST claim's time is kept
	(GroupBonusClaimedAt); later ones are counted in GroupBonusRepeats so a
	double grant in the game is visible. HarvestService.HasClaimedGroupBonus
	answers from the summary - a convenience, not the game's entitlement
	record: the game must keep its own "already paid" flag, because Harvest
	may be off or unrecorded.

	FAVORITES: no Roblox API tells whether a player favourited the experience
	(H0 audit). Always "unavailable"; never asserted.
]]

local Community = {}
Community.Name = "Community"

-- The group id to check now, or (nil, status) when there is none.
function Community.ResolveGroup(ctx: any): (number?, string)
	local group = ctx.group()
	if group.Mode == "Off" then
		return nil, "off"
	elseif group.Mode == "Id" then
		return group.GroupId, "unknown"
	end
	local creatorType, creatorId = ctx.platform.GameOwner()
	if creatorType == "Group" and type(creatorId) == "number" and creatorId > 0 then
		return creatorId, "unknown"
	end
	return nil, "unavailable"
end

local function setStatus(ctx: any, state: any, status: string, groupId: number?, now: number)
	if not ctx.writable(state) then
		return
	end
	local c = state.Summary.Community
	local id = groupId or 0
	if c.GroupId ~= id then
		-- Another group than the saved fields describe.
		c.GroupId = id
		c.EverGroupMember = false
		c.GroupCheckedAt = 0
		c.LastVerifiedMember = ""
	end
	c.IsGroupMember = status
	if status == "true" then
		c.EverGroupMember = true
	end
	if status == "true" or status == "false" then
		c.GroupCheckedAt = now
		c.LastVerifiedMember = status
	end
	state.Dirty = true
end

local function check(ctx: any, state: any, now: number)
	local sc = state.Scratch
	local groupId, status = Community.ResolveGroup(ctx)
	if groupId == nil then
		sc.GroupPending = false
		if sc.GroupReported ~= status then
			sc.GroupReported = status
			setStatus(ctx, state, status, nil, now)
			ctx.emit(state.Player, "group_checked", { IsMember = status },
				string.format("%s:group:%s", state.SessionId, status))
		end
		return
	end
	if sc.GroupInFlight then
		return
	end
	sc.GroupInFlight = true
	sc.GroupAttempts = (sc.GroupAttempts or 0) + 1
	sc.GroupCheckedId = groupId
	task.spawn(function()
		local ok, result = pcall(ctx.platform.IsInGroup, state.Player, groupId)
		sc.GroupInFlight = false
		if sc.GroupCheckedId ~= groupId then
			return -- group changed meanwhile; the newer check reports
		end
		local final: string?
		if ok and type(result) == "boolean" then
			final = if result then "true" else "false"
		else
			ctx.stats.GroupCheckFailures += 1
			if sc.GroupAttempts >= ctx.config.Tunables.GroupCheckAttempts then
				final = "unknown"
			end
		end
		if final == nil then
			sc.GroupPending = true -- retried on the next tick
			return
		end
		sc.GroupPending = false
		local at = ctx.clock()
		setStatus(ctx, state, final, groupId, at)
		local key = string.format("%d:%s", groupId, final)
		if sc.GroupReported ~= key then
			sc.GroupReported = key
			ctx.emit(state.Player, "group_checked", { IsMember = final, GroupId = groupId },
				string.format("%s:group:%d", state.SessionId, groupId))
		end
	end)
end

function Community.OnReady(ctx: any, state: any, now: number, writable: boolean)
	if writable then
		local c = state.Summary.Community
		c.Favorites = "unavailable"
		-- Status carried from a previous session is stale until checked
		-- (LastVerifiedMember + GroupCheckedAt keep the last real answer).
		if c.IsGroupMember == "true" or c.IsGroupMember == "false" then
			c.IsGroupMember = "unknown"
		end
		state.Dirty = true
	end
	check(ctx, state, now)
end

function Community.OnTick(ctx: any, state: any, now: number)
	if state.Scratch.GroupPending then
		check(ctx, state, now)
	end
end

-- Group setting changed (SetGroup): check again from scratch.
function Community.OnGroupChanged(ctx: any, state: any, now: number)
	local sc = state.Scratch
	sc.GroupAttempts = 0
	sc.GroupReported = nil
	sc.GroupCheckedId = nil
	sc.GroupInFlight = false
	check(ctx, state, now)
end

function Community.OnEvent(ctx: any, state: any, envelope: any, writable: boolean)
	if not writable or envelope.EventType ~= "group_bonus_claimed" then
		return
	end
	local c = state.Summary.Community
	if c.GroupBonusClaimedAt == 0 then
		c.GroupBonusClaimedAt = envelope.ServerTime
	else
		c.GroupBonusRepeats += 1
	end
	state.Dirty = true
end

return Community
