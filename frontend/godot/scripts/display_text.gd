extends RefCounted
## Shared bounded label formatting. Unicode remains intact; layout/terminal
## controls and explicit bidi overrides are replaced with spaces.
static func single_line(value: Variant, maximum: int) -> String:
	if not value is String:
		return ""
	var result := ""
	for index in range(maxi(0, mini(value.length(), maximum))):
		var codepoint: int = value.unicode_at(index)
		if codepoint < 32 or (codepoint >= 127 and codepoint <= 159) \
			or codepoint in [0x2028, 0x2029] or (codepoint >= 0x202a and codepoint <= 0x202e) \
			or (codepoint >= 0x2066 and codepoint <= 0x2069):
			result += " "
		else:
			result += value[index]
	return result.strip_edges()
