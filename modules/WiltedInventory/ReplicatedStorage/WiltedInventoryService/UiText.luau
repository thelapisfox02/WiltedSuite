--!strict
--[[
	=== UiText ================================================================

	ONE PLACE that styles text created in CODE, so a generated label matches the
	authored ones instead of carrying whatever default the script that made it
	happened to set.

	THE HOUSE STYLE, measured from the authored GUI (every tagged label in
	StarterGui.GameGui agrees on it):

	    FontFace   Ubuntu, Bold
	    UIStroke   black, Thickness 3, StrokeSizingMode FixedSize,
	               tagged "ScaledStroke"

	WHY THE TAG AND NOT A THICKNESS. GameGui.BetterScaledStrokes owns stroke
	scaling: it picks up anything tagged "ScaledStroke", reads the FixedSize
	thickness as the wanted PIXEL thickness, stores it in a "StrokeThickness"
	attribute, flips the stroke to ScaledSize and then recomputes the real
	thickness from the parent's AbsoluteSize whenever it changes. So the correct
	way to ask for "3px of outline" is to set Thickness = 3 with FixedSize and
	apply the tag - never to compute a scaled number here. Two services both
	doing that maths is how they drift.

	The tag is applied LAST, because BetterScaledStrokes reads the thickness and
	sizing mode at the moment the tag lands.
]]

local CollectionService = game:GetService("CollectionService")

local UiText = {}

UiText.FONT = Font.fromName("Ubuntu", Enum.FontWeight.Bold)
UiText.STROKE_TAG = "ScaledStroke"
UiText.STROKE_THICKNESS = 3
UiText.STROKE_COLOR = Color3.fromRGB(0, 0, 0)

--[[
	Apply the house font to an existing TextLabel/TextButton/TextBox.

	Writes FontFace rather than the legacy `Font` enum: `Font` cannot express a
	weight, so `Enum.Font.GothamBold` and friends are both the wrong family and
	a dead end for weight changes.
]]
function UiText.applyFont(label: Instance)
	if not label:IsA("TextLabel") and not label:IsA("TextButton") and not label:IsA("TextBox") then
		return
	end
	label.FontFace = UiText.FONT
end

--[[
	Give a text object the house outline, idempotently.

	Reuses an existing UIStroke child when there is one, so calling this on an
	already-styled label (or on the same label every refresh) cannot stack a
	second outline - the same duplication hazard that bit the plot labels.
]]
function UiText.applyStroke(label: Instance, thickness: number?): UIStroke?
	if not label:IsA("GuiObject") then
		return nil
	end

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = label
	end

	stroke.Color = UiText.STROKE_COLOR
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	-- FixedSize + the tag is the contract BetterScaledStrokes reads; it rewrites
	-- the mode to ScaledSize itself once it has taken the pixel value.
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
	stroke.Thickness = thickness or UiText.STROKE_THICKNESS

	-- Last, and only once: the tag is what hands the stroke over.
	if not CollectionService:HasTag(stroke, UiText.STROKE_TAG) then
		CollectionService:AddTag(stroke, UiText.STROKE_TAG)
	end

	return stroke
end

-- Font + stroke in one call, for the common case.
function UiText.style(label: Instance, thickness: number?): Instance
	UiText.applyFont(label)
	UiText.applyStroke(label, thickness)
	return label
end

--[[
	A new TextLabel already carrying the house style.

	`props` is applied BEFORE the stroke, so a caller can override Thickness-
	relevant parents and still get a correctly scaled outline.
]]
function UiText.label(props: { [string]: any }?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true

	if props then
		for key, value in pairs(props) do
			(label :: any)[key] = value
		end
	end

	UiText.style(label)
	return label
end

return UiText
