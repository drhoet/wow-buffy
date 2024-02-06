local Buffy = LibStub("AceAddon-3.0"):NewAddon("Buffy", "AceConsole-3.0")

-----------------
-- Addon state --
-----------------
Buffy.groupsRepository = { -- the groups we have + which buffs they require
	items = {},
	maxGroup = 0,
	GetOrCreate = function(self, groupNb)
		if groupNb > self.maxGroup then
			self.maxGroup = groupNb
		end
		local ret = self.items[groupNb]
		if not ret then
			ret = Buffy.NewGroup(groupNb)
			self.items[groupNb] = ret
		end
		return ret
	end,
	Clear = function(self)
		self.items = {}
		self.maxGroup = 0
	end,
	Iterator = function(self)
		local i = 0
		return function()
			i = i + 1
			if i <= self.maxGroup then -- make sure we don't keep creating groups at the end
				return self:GetOrCreate(i) -- this gets rid of gaps in the list
			else
				return nil
			end
		end
	end
}
Buffy.buffersRepository = { -- the players that can buff
	items = {},
	Add = function(self, player)
		self.items[player.name] = player
	end,
	Clear = function(self)
		self.items = {}
	end,
	Iterate = function(self)
		local idx = nil
		return function()
			local value = nil
			idx, value = next(self.items, idx)
			return value
		end
	end,
	IterateByName = function(self)
		local order = {}
		for name, _ in pairs(self.items) do
			table.insert(order, name)
		end
		table.sort(order)

		local i = 0
		return function()
			i = i + 1
			return self.items[order[i]]
		end
	end
}
Buffy.selectedUiIcon = nil
local BUFFS = {} -- a static list of the supports buffs

---------------
-- Libraries --
---------------
local LibGroupTalents = LibStub("LibGroupTalents-1.0")
local AceGUI = LibStub("AceGUI-3.0")

----------------------
-- Helper Functions --
----------------------
function Buffy.FindBufferWithLeastAssignments(buff)
	local chosen = nil
	for cursor in Buffy.buffersRepository:Iterate() do
		if cursor:CanCastBuff(buff) then
			if not chosen then
				chosen = cursor
			elseif cursor:CalculateAssignmentWeight() < chosen:CalculateAssignmentWeight() then
				chosen = cursor
			end
		end
	end
	return chosen
end

function Buffy.NewPlayer(name, class)
	return {
		name = name,
		class = class,
		_buffs = {},
		_assignments = {},
		CalculateAssignmentWeight = function(self)
			local ret = 0
			for _, a in pairs(self._assignments) do
				ret = ret + a.buff.cost
			end
			return ret
		end,
		AddCastableBuff = function(self, buff)
			self._buffs[buff] = buff
		end,
		CanCastBuff = function(self, buff)
			return self._buffs[buff] ~= nil
		end,
		CanCastAnyBuffs = function(self)
			return next(self._buffs) ~= nil
		end,
		AssignBuff = function(self, buff, group)
			table.insert(self._assignments, Buffy.NewAssignment(group, buff, self))
		end,
		UnAssignBuff = function(self, buff, group)
			local oldAssignments = self._assignments
			self._assignments = {}
			for _, a in pairs(oldAssignments) do
				if not (a.group == group and a.buff == buff) then
					table.insert(self._assignments, a)
				end
			end
		end,
		GetAssignmentsForGroup = function(self, group)
			local ret = {}
			for _, a in pairs(self._assignments) do
				if a.group == group then
					table.insert(ret, a)
				end
			end
			return ret
		end,
		IsBuffingOnGroup = function(self, buff, group)
			for _, a in pairs(self._assignments) do
				if a.buff == buff and a.group == group then
					return true
				end
			end
			return false
		end
	}
end

function Buffy.NewGroup(nb)
	return {
		nb = nb,
		_buffs = {},
		_assignments = {},
		AddRequiredBuff = function(self, buff)
			self._buffs[buff.name] = buff
		end,
		RequiresBuff = function(self, buff)
			return self._buffs[buff.name] ~= nil
		end,
		AssignBuffer = function(self, buff, player)
			table.insert(self._assignments, Buffy.NewAssignment(self, buff, player))
		end,
		UnAssignBuffer = function(self, buff, player)
			local oldAssignments = self._assignments
			self._assignments = {}
			for _, a in pairs(oldAssignments) do
				if not (a.player == player and a.buff == buff) then
					table.insert(self._assignments, a)
				end
			end
		end,
		GetBuffer = function(self, buff)
			for _, a in pairs(self._assignments) do
				if a.buff == buff then
					return a.player
				end
			end
		end
	}
end

function Buffy.NewAssignment(group, buff, player)
	return {
		group = group,
		buff = buff,
		player = player
	}
end

function Buffy.AssignBuffOnGroupToPlayer(buff, group, player)
	player:AssignBuff(buff, group)
	group:AssignBuffer(buff, player)
end

function Buffy.UnAssignBuffOnGroupFromPlayer(buff, group, player)
	player:UnAssignBuff(buff, group)
	group:UnAssignBuffer(buff, player)
end

function Buffy.CanSwapAssignment(buff, fromPlayer, toPlayer, fromGroup, toGroup)
	if fromPlayer == toPlayer and fromGroup ~= toGroup then
		-- a player will buff another group
		return toGroup:RequiresBuff(buff) and not fromPlayer:IsBuffingOnGroup(buff, toGroup)
	elseif fromPlayer ~= toPlayer and fromGroup == toGroup then
		-- a group will be buffed by another player
		-- note that here it is not possible that the buff is already there
		return toPlayer:CanCastBuff(buff)
	else
		return false
	end
end

function Buffy.SwapAssignment(source, toPlayer, toGroup)
	if Buffy.CanSwapAssignment(source.buff, source.player, toPlayer, source.group, toGroup) then
		Buffy.UnAssignBuffOnGroupFromPlayer(source.buff, source.group, source.player)
		Buffy.AssignBuffOnGroupToPlayer(source.buff, toGroup, toPlayer)
		if source.player == toPlayer then
			-- we need to swap the target buff also, otherwise the source group is not buffed anymore
			local oldBuffer = toGroup:GetBuffer(source.buff)
			if oldBuffer then
				Buffy.UnAssignBuffOnGroupFromPlayer(source.buff, toGroup, oldBuffer)
				Buffy.AssignBuffOnGroupToPlayer(source.buff, source.group, oldBuffer)
			else
				print('ERROR: there was nobody buffing', source.buff.displayName, 'on', toGroup.nb)
			end
		end
		return true
	else
		return false
	end
end

---------------
-- UI --
---------------
function Buffy.UiUpdateRow(uiParent, rowNb, player)
	local uiRow = uiParent.uiRows[rowNb]
	if not uiRow then
		uiRow = CreateFrame("Frame", uiParent:GetName().."_Row"..rowNb, uiParent)
		uiRow:SetHeight(20)
		if rowNb == 1 then
			-- attach to parent
			uiRow:SetPoint("TOPLEFT", uiParent, "TOPLEFT", 10, 0)
			uiRow:SetPoint("TOPRIGHT", uiParent, "TOPRIGHT")
		else
			-- attach to row above
			uiRow:SetPoint("TOPLEFT", uiParent.uiRows[rowNb - 1], "BOTTOMLEFT")
			uiRow:SetPoint("TOPRIGHT", uiParent.uiRows[rowNb - 1], "BOTTOMRIGHT")
		end
		uiRow.uiCells = {}
		uiRow.uiParent = uiParent
		uiParent.uiRows[rowNb] = uiRow
	end

	local lastCellIdx = Buffy.groupsRepository.maxGroup + 1

	-- hide cells that we don't need anymore
	for i = lastCellIdx + 1, table.getn(uiRow.uiCells) do
		uiRow.uiCells[i]:Hide()
	end

	-- create / update cells
	for i = lastCellIdx, 1, -1 do
		local uiCell = uiRow.uiCells[i]
		if not uiCell then
			uiCell = CreateFrame("Frame", uiRow:GetName().."_Cell"..i, uiRow)
			uiCell:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background", tile=false})
			uiCell:SetWidth(40)
			uiCell.text = uiCell:CreateFontString(uiCell:GetName().."Text", "OVERLAY", "GameFontNormal")
			uiCell.text:SetAllPoints()
			if i == 1 then
				uiCell.text:SetJustifyH("LEFT")
			end
			uiCell.icon1 = uiCell:CreateTexture()
			uiCell.icon1:SetWidth(20)
			uiCell.icon1.uiCell = uiCell
			uiCell.icon2 = uiCell:CreateTexture()
			uiCell.icon2:SetWidth(20)
			uiCell.icon2.uiCell = uiCell
			uiCell.icon2:SetPoint("TOPLEFT", uiCell.icon1, "TOPRIGHT")
			uiCell.icon2:SetPoint("BOTTOMLEFT", uiCell.icon1, "BOTTOMRIGHT")
			uiCell:EnableMouse(true)
			uiCell:SetScript("OnMouseDown", function(self, button)
				if button == "LeftButton" then
					Buffy_OnCellClick(self)
				end
			end)
			uiCell.uiRow = uiRow
			uiRow.uiCells[i] = uiCell
		end
		-- fix cell positioning
		if i == lastCellIdx then
			uiCell:SetPoint("TOPRIGHT", uiRow, "TOPRIGHT")
			uiCell:SetPoint("BOTTOMRIGHT", uiRow, "BOTTOMRIGHT")
		elseif i == 1 then
			uiCell:SetPoint("TOPRIGHT", uiRow.uiCells[i+1], "TOPLEFT")
			uiCell:SetPoint("BOTTOMRIGHT", uiRow.uiCells[i+1], "BOTTOMLEFT")
			uiCell:SetPoint("TOPLEFT", uiRow, "TOPLEFT")
			uiCell:SetPoint("BOTTOMLEFT", uiRow, "BOTTOMLEFT")
		else
			uiCell:SetPoint("TOPRIGHT", uiRow.uiCells[i+1], "TOPLEFT")
			uiCell:SetPoint("BOTTOMRIGHT", uiRow.uiCells[i+1], "BOTTOMLEFT")			
		end
		-- fix cell metadata
		uiCell.player = player
		if i > 1 then
			uiCell.group = Buffy.groupsRepository:GetOrCreate(i - 1)
		else
			uiCell.group = nil
		end
		-- reset any cell markings
		uiCell:SetBackdropColor(0, 0, 0, 0)
		uiCell.icon1:SetVertexColor(1, 1, 1, 1)
		uiCell.icon2:SetVertexColor(1, 1, 1, 1)
		-- fix cell contents
		uiCell.icon1.assignment = nil
		uiCell.icon2.assignment = nil
		if player then
			if i == 1 then
				uiCell.text:SetText(player.name .. " (" .. player:CalculateAssignmentWeight() .. ")")
				uiCell.icon1:Hide()
				uiCell.icon2:Hide()
			else
				uiCell.text:Hide()
				local assignments = player:GetAssignmentsForGroup(uiCell.group)
				uiCell.icon1.assignment = assignments[1]
				uiCell.icon2.assignment = assignments[2]
				if table.getn(assignments) > 1 then
					uiCell.icon1:SetTexture(assignments[1].buff.icon)
					uiCell.icon1:SetPoint("TOPLEFT", uiCell, "TOPLEFT", 0, 0)
					uiCell.icon1:SetPoint("BOTTOMLEFT", uiCell, "BOTTOMLEFT", 0, 0)
					uiCell.icon1:Show()
					uiCell.icon2:SetTexture(assignments[2].buff.icon)
					uiCell.icon2:Show()
				elseif table.getn(assignments) == 0 then
					uiCell.icon1:Hide()
					uiCell.icon2:Hide()
				else
					uiCell.icon1:SetTexture(assignments[1].buff.icon)
					uiCell.icon1:Show()
					uiCell.icon1:SetPoint("TOPLEFT", uiCell, "TOPLEFT", 10, 0)
					uiCell.icon1:SetPoint("BOTTOMLEFT", uiCell, "BOTTOMLEFT", 10, 0)
					uiCell.icon2:Hide()
				end
			end
		else
			-- no player data for this row, just add the group numbers
			if i == 1 then
				uiCell.text:Hide()
			else
				uiCell.text:SetText(i - 1)
			end
			uiCell.icon1:Hide()
			uiCell.icon2:Hide()
		end
		uiCell:Show()
	end
end

function Buffy.UiUpdate()
	local container = BuffyMainFrame_Contents
	if not container.uiRows then
		container.uiRows = {}
	end

	-- create all player rows
	local rows = {}
	local maxGroup = -1
	Buffy.UiUpdateRow(container, 1, nil) -- this is the title row
	local i = 0
	for player in Buffy.buffersRepository:IterateByName() do
		i = i + 1
		Buffy.UiUpdateRow(container, i + 1, player)
	end
end

local function Buffy_IsInside(x, y, region)
	local left, bottom, width, height = region:GetRect()
	if left and bottom and width and height then
  		return (x >= left) and (x <= left + width) and (y >= bottom) and (y <= bottom + height)
	else
		return false
	end
end

local function Buffy_UiMarkAsSource(texture)
	texture:SetVertexColor(0.75, 0, 0, 1)
end

local function Buffy_UiMarkAllPossibleTargets(texture)
	local tableRoot = texture.uiCell.uiRow.uiParent
	for _, uiRow in pairs(tableRoot.uiRows) do
		for _, uiCell in pairs(uiRow.uiCells) do
			if uiCell.player and uiCell.group then
				if Buffy.CanSwapAssignment(texture.assignment.buff, texture.assignment.player, uiCell.player, texture.assignment.group, uiCell.group) then
					-- implementation remark: the backdrop is not visible if there are two icons in the cell,
					-- but we don't care because such cells are never a valid target anyways, as they already
					-- have a buffer for all buffs
					uiCell:SetBackdropColor(0, 1, 0, 1)
				end
			end
		end
	end
end

function Buffy_OnCellClick(cell)
	local x, y = GetCursorPosition()
	local s = cell:GetEffectiveScale();
	x = x / s
	y = y / s

	if selectedUiIcon then
		-- we already have a source icon selected
		local source = selectedUiIcon
		local target = cell
		if source.uiCell == target then
			BuffyMainFrame_StatusBar_Text:SetText("Cancelled by user")
		else
			local ret = Buffy.SwapAssignment(selectedUiIcon.assignment, target.player, target.group)
			if ret then
				BuffyMainFrame_StatusBar_Text:SetText("Swapped!")
			else
				BuffyMainFrame_StatusBar_Text:SetText("Illegal swap!")
			end
		end
		selectedUiIcon = nil
		Buffy.UiUpdate()
	else
		-- we have nothing selected
		local clickedIcon = nil
		if Buffy_IsInside(x, y, cell.icon1) then
			clickedIcon = cell.icon1
		elseif Buffy_IsInside(x, y, cell.icon2) then
			clickedIcon = cell.icon2
		end
		if clickedIcon and clickedIcon.assignment then
			selectedUiIcon = clickedIcon
			Buffy_UiMarkAsSource(selectedUiIcon)
			Buffy_UiMarkAllPossibleTargets(selectedUiIcon)
			BuffyMainFrame_StatusBar_Text:SetText("Select the target you want to swap to...")
		end
	end
end

function Buffy_OnAssignClick(button)
	Buffy.Assign()
end

function Buffy_OnAnnounceClick(button)
	local classDropdownValue = {
		druid = true,
		mage = true,
		priest = true
	}
	local targetDropdownValue = 'RAID'

	local dialog = AceGUI:Create('Window')
	dialog:SetTitle('Announce - Buffy')
	dialog:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget) end)
	dialog:SetLayout("List")
	dialog:EnableResize(false)
	dialog:SetWidth(225)
	dialog:SetAutoAdjustHeight(true)
	dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

	local classDropdown = AceGUI:Create('Dropdown')
	classDropdown:SetLabel('Announce assignments for classes')
	classDropdown:SetMultiselect(true)
	classDropdown:SetList({})
	classDropdown:AddItem('druid', 'Druid')
	classDropdown:AddItem('mage', 'Mage')
	classDropdown:AddItem('priest', 'Priest')
	classDropdown:SetItemValue('druid', classDropdownValue.druid)
	classDropdown:SetItemValue('mage', classDropdownValue.mage)
	classDropdown:SetItemValue('priest', classDropdownValue.priest)
	classDropdown:SetCallback("OnValueChanged", function(frame, event, key, checked)
		classDropdownValue[key] = checked
	end)
	dialog:AddChild(classDropdown)

	local targetDropdown = AceGUI:Create('Dropdown')
	targetDropdown:SetLabel('Announce target')
	targetDropdown:SetList({})
	targetDropdown:AddItem('WHISPER', 'Whisper')
	targetDropdown:AddItem('PARTY', 'Party')
	targetDropdown:AddItem('RAID', 'Raid')
	targetDropdown:AddItem('GUILD', 'Guild')
	targetDropdown:SetValue(targetDropdownValue)
	-- OnValueChanged callback is defined a bit below
	dialog:AddChild(targetDropdown)

	local whisperTargetEditBox = AceGUI:Create('EditBox')
	whisperTargetEditBox:SetLabel('Whisper Target')
	whisperTargetEditBox:SetDisabled(true)
	dialog:AddChild(whisperTargetEditBox)

	-- need to be defined AFTER whisperTargetEditBox
	targetDropdown:SetCallback("OnValueChanged", function(frame, event, value)
		whisperTargetEditBox:SetDisabled(value ~= 'WHISPER')
		targetDropdownValue = value
	end)
	

	local okButton = AceGUI:Create('Button')
	okButton:SetText('Announce')
	okButton:SetCallback("OnClick", function()
		dialog:Hide()
		Buffy.Announce(targetDropdownValue, whisperTargetEditBox.editbox:GetText(), classDropdownValue)
	end)
	dialog:AddChild(okButton)

	dialog.LayoutFinished = function(self, _, height)
		dialog:SetHeight(height + 47)
	end

	dialog:Show()
end

--------------
-- Commands --
--------------
function Buffy.Announce(target, whisperTarget, classes)
	local str = {}
	for buffer in Buffy.buffersRepository:IterateByName() do
		local groupsPerBuff = {}
		for group in Buffy.groupsRepository:Iterator() do
			for i, a in ipairs(buffer:GetAssignmentsForGroup(group)) do
				print(a.player.class)
				print(string.lower(a.player.class))
				print(classes.druid)
				if classes[string.lower(a.player.class)] then
					if groupsPerBuff[a.buff] == nil then
						groupsPerBuff[a.buff] = {}
					end
					table.insert(groupsPerBuff[a.buff], "g" .. group.nb)
				end
			end
		end
		local tmpStr = {}
		for buff, groupNbs in pairs(groupsPerBuff) do
			table.insert(tmpStr, buff.displayName .. " -> " .. table.concat(groupNbs, ", "))
		end
		if #tmpStr > 0 then
			table.insert(str, buffer.name .. ": " .. table.concat(tmpStr, ", "))
		end
	end
	SendChatMessage(table.concat(str, " // "), target, nil, whisperTarget)
end

function Buffy.InspectRaid()
	Buffy.groupsRepository:Clear()
	Buffy.buffersRepository:Clear()

	local maxGroup = -1
	-- iterate the raid to figure out who can buff and which group needs which buffs
	for i = 1, 40 do
		local name, _, subgroup, _, class, _, _, _, _, role, isML = GetRaidRosterInfo(i);
		if name then
			local player = Buffy.NewPlayer(name, class)
			local group = Buffy.groupsRepository:GetOrCreate(subgroup)
			
			for name, buff in pairs(BUFFS) do
				if buff:canBeCastBy(player) then
					player:AddCastableBuff(buff)
				end
				if buff:isRequiredBy(player) then
					group:AddRequiredBuff(buff)
				end
			end

			if player:CanCastAnyBuffs() then
				Buffy.buffersRepository:Add(player)
			end

			if subgroup > maxGroup then
				maxGroup = subgroup
			end
		end
	end
end

function Buffy.Assign()
	Buffy.InspectRaid()
	
	-- sort the buffs by assignPrio
	local buffAssignOrder = {}
	for buffType, _ in pairs(BUFFS) do
		table.insert(buffAssignOrder, buffType)
	end
	table.sort(buffAssignOrder, function(bt1, bt2) return BUFFS[bt1].assignPrio > BUFFS[bt2].assignPrio end)
	
	-- assign groups to buffers
	for _, buffType in ipairs(buffAssignOrder) do
		local buff = BUFFS[buffType]
		for group in Buffy.groupsRepository:Iterator() do
			if group:RequiresBuff(buff) then
				local player = Buffy.FindBufferWithLeastAssignments(buff)
				if player then
					Buffy.AssignBuffOnGroupToPlayer(buff, group, player)
				end
			end
		end
	end

	Buffy.UiUpdate()
end

function Buffy:OnInitialize()
	Buffy:RegisterChatCommand("buffy", "OnSlashCommand")
end

function Buffy:OnSlashCommand(msg)
	local _, _, cmd, remainder = string.find(msg, "%s?(%w+)%s?(.*)")
	local args = {}
	for w in string.gmatch(remainder, "([^%s]+)") do
		table.insert(args, w)
	end
	if cmd == "assign" then
		Buffy.Assign()
	else
		Buffy:Print("Invalid command")
	end
end

function Buffy:OnEnable()
	BUFFS.stamina = {
		cost = 1,
		name = "stamina",
		displayName="stam",
		icon = "Interface\\Icons\\Inv_misc_questionmark",
		canBeCastBy = function(self, player)
			return string.lower(player.class) == "priest"
		end,
		isRequiredBy = function(self, player)
			return true
		end,
		assignPrio = 0
	}
	_, _, BUFFS.stamina.icon, BUFFS.stamina.cost = GetSpellInfo(21564)
	
	BUFFS.spirit = {
		cost = 1,
		name = "spirit",
		displayName="spi",
		icon = "Interface\\Icons\\Inv_misc_questionmark",
		canBeCastBy = function(self, player)
			return string.lower(player.class) == "priest" and LibGroupTalents:UnitHasTalent(player.name, "Divine Spirit")
		end,
		isRequiredBy = function(self, player)
			return UnitPowerMax(player.name, 0) > 0
		end,
		assignPrio = 100
	}
	_, _, BUFFS.spirit.icon, BUFFS.spirit.cost = GetSpellInfo(27681)
	
	BUFFS.gotw = {
		cost = 1,
		name = "gotw",
		displayName="gotw",
		icon = "Interface\\Icons\\Inv_misc_questionmark",
		canBeCastBy = function(self, player)
			return string.lower(player.class) == "druid"
		end,
		isRequiredBy = function(self, player)
			return true
		end, 
		assignPrio = 0
	}
	_, _, BUFFS.gotw.icon, BUFFS.gotw.cost = GetSpellInfo(21850)
	
	BUFFS.intellect = {
		cost = 1,
		name = "intellect",
		displayName="int",
		icon = "Interface\\Icons\\Inv_misc_questionmark",
		canBeCastBy = function(self, player)
			return string.lower(player.class) == "mage"
		end,
		isRequiredBy = function(self, player)
			return UnitPowerMax(player.name, 0) > 0
		end, 
		assignPrio = 0
	}
	_, _, BUFFS.intellect.icon, BUFFS.intellect.cost = GetSpellInfo(23028)
end