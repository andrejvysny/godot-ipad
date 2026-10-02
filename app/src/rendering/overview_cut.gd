class_name OverviewCut
extends RefCounted
## Hierarchy cut of the overview groups (LOD-03), generalized to any number of levels. Walking from the coarsest
## level down, a group is active iff its group level is at least its own level, its proxy is current and complete,
## neither it nor any group below it is blocked (pinned cell, selected object, pending invalidation) and no
## ancestor is active; otherwise its children decide, and cells under no active group stay individual.
## Coarser activation is immediate; finer upgrades wait for settled navigation. Blocks retire groups immediately;
## unblocked descendants take over at once. Pure state transition: the caller applies off, then on.


## Fills `off` / `on` and returns true when a finer upgrade waits for settled navigation.
## groups: level -> Dictionary(Vector2i -> OverviewGroup); blocked: level -> Dictionary(Vector2i -> true).
static func compute(groups: Array[Dictionary], blocked: Array[Dictionary], settled: bool,
		off: Array[OverviewGroup], on: Array[OverviewGroup]) -> bool:
	var top := groups.size() - 1
	for lvl in groups.size():
		for g: OverviewGroup in groups[lvl].values():
			g.sub_blocked = g.invalidated or (blocked[lvl] as Dictionary).has(g.key)
	for lvl in top:
		for g: OverviewGroup in groups[lvl].values():
			if g.sub_blocked:
				var p: OverviewGroup = groups[lvl + 1].get(g.parent_key)
				if p != null:
					p.sub_blocked = true
	var withheld := false
	for lvl in range(top, -1, -1):
		for g: OverviewGroup in groups[lvl].values():
			var parent: OverviewGroup = null if lvl == top else groups[lvl + 1].get(g.parent_key)
			g.cut_anc = parent != null and (parent.cut_on or parent.cut_anc)
			g.cut_handoff = parent != null and (parent.cut_handoff
					or (parent.active and not parent.cut_on and parent.sub_blocked))
			var wants := not g.cut_anc and g.current and g.complete and g.group_level >= lvl and not g.sub_blocked
			if g.active:
				if g.cut_anc or g.sub_blocked or (not wants and settled):
					off.append(g)
					g.cut_on = false
				else:
					g.cut_on = true
					withheld = withheld or not wants
			elif wants:
				on.append(g)
				g.cut_on = true
			else:
				g.cut_on = false
	return withheld
