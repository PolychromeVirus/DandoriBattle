// ============================================================================
// scrDialog - narrative text lookup.
//
// One place to write story/log text, keyed by a DIALOG ID string. The engine
// only ever asks "what's the text for this id?" - it neither knows nor cares
// what ids exist, so adding a beat is purely a matter of filling in a case
// below. Returning "" means "nothing to say here", and the caller SKIPS the
// screen entirely rather than showing an empty bubble - so every case left
// blank simply doesn't interrupt play.
//
// Currently used by: the between-mission adventure log (adventure_dialog_id in
// objGame Create_0 builds the id; the "advLore" screen in Draw_64 renders it,
// streaming letter-by-letter with sfxText - a computer-log blip, as opposed to
// the tutorial's sfxTalk voice chatter).
// ============================================================================

/// Text for a dialog id, or "" if that id has nothing to show (the caller then
/// skips its screen). Long entries are fine - the log bubble wraps, streams the
/// text in, and offers Skip; use "\n" for a hard line break / paragraph gap.
///
/// ADVENTURE IDS: built from the BOARD'S OWN id (as in adventure.json), so an id
/// reads exactly like the map it belongs to - "adv1_1_cleared" is board adv1_1.
/// Both halves are 1-BASED, matching the data files. Formats:
///   "<boardId>_cleared"    - that mission was just beaten, and it is NOT the
///                            last of its scenario (the last one fires
///                            "_complete" instead - see below).
///   "adv<N>_complete"      - the scenario's FINAL mission was beaten, i.e. the
///                            whole campaign is done. N is 1-based.
///   "<boardId>_failed"     - ran out of days on that mission.
/// The full set for the current 3 scenarios / 20 boards is stubbed out below.
function dialog_text(_dialogId) {
    switch (_dialogId) {

        // ================= Stranded Captain (adv1_*, 6 missions) =================
		case "adv1_preamble":
			return "SHIP STATUS: CRITICAL\n\nI have crash landed on this distant planet once again, but something this time feels... Different. The environment has changed dramatically. It looks superficially very similar, but everything seems to move strangely. I will need to enlist the help of the Pikmin once again to retrieve my ship parts if I want to return home. My initial landing site I will name The Graceless Lot."
        case "adv1_1_cleared":
            return "SHIP STATUS: BARELY FUNCTIONAL\n\nIt's very different this time. I've never witnessed such patient creatures and organized locations. I've cleared this area out, but I'll need to keep exploring for the rest of my parts, there's no way I'll be able to escape this planet without my ship 100% complete. I just hope my life support function will last long enough for me to do so. I estimate I have about 30 days of resources, including the time I spent at the Graceless Lot. I've set my sights on a new bountiful location to look for more, I will call it The Roofed Riverside.";
        case "adv1_2_cleared": return "SHIP STATUS: FUNCTIONAL\n\nJust as I feared, these creatures are starting to find my ship parts and guarding them as if it were their offspring. I'll need to think a little bit harder as I continue to search for the parts, I know from experience the environment here isn't forgiving. In the distance across the river I've identified a new area that seems to have more of the parts of my ship. I'll call this new location The Exposed Riverbank";
        case "adv1_3_cleared": return "SHIP STATUS: PASSABLE\n\nI'm starting to get tired, most likely a side effect of the depletion of my life support. I must not stop now! I've cleared out the nearby locations to positive results, but I must venture further away from the crash site now that I am able. I heard some concerning roars as I ascended last night, and I may have located the source. This 'Screeching Bog' as I call it will only be more treacherous than the last locations.";
        case "adv1_4_cleared": return "SHIP STATUS: GOOD\n\nI'm glad to be out of there. The roaring and the fumes were a decidedly unwelcome environment, but retrieving my radar functionality will make locating the rest of the parts a breeze. Though it seems retrieving them will be its own unique challenge now. I'm tracking a collection of parts over near a very dry region I've dubbed 'The Muted Desert'. It's quieter than the previous location, which I'll take as a small blessing.";
        case "adv1_5_cleared": return "SHIP STATUS: COMPLETE\n\nI've restored my ship to complete function, but something feels wrong. My radar is still sensing missing pieces of the ship, and I think I know what they are. It may be selfish, but I must try to retrieve those last few parts, for personal reasons. If I cannot retrieve them in the time I have left, then perhaps I will be seeing this planet again soon, when I return. Either way, my final base of operations will be in this 'Klepto's Cavern'. Let us hope another one isn't necessary.";
        // (adv1_6 is the last mission -> fires "adv1_complete", not "_cleared")
        case "adv1_complete":  return "SHIP STATUS: PERFECT\n\n I've done it! Regardless of how much this planet may change, I, Captain Olimar, will never fall to it. I once again bid farewell to my squad of Pikmin, and despite the bitter taste of goodbye, I hope to never need their assistance again. I write this final log as I am returning home, and as soon as I touch ground I will be starting on my retirement paperwork. I am in need of a very, very long break.";

        case "adv1_1_failed":  return "LIFE SUPPORT FUNCTIONS: DEPLETED\n\nWell, this is it, this unforgiving planet has finally bested me, Captain Olimar. I write this final log as a warning to anyone who finds themself on this wretched planet. Leave. Leave and never return. If you don't, you will meet the same fate I have. All the loved ones I have with me at the end are these, my Pikmin... Goodnight...";
        case "adv1_2_failed":  return "LIFE SUPPORT FUNCTIONS: DEPLETED\n\nWell, this is it, this unforgiving planet has finally bested me, Captain Olimar. I write this final log as a warning to anyone who finds themself on this wretched planet. Leave. Leave and never return. If you don't, you will meet the same fate I have. All the loved ones I have with me at the end are these, my Pikmin... Goodnight...";
        case "adv1_3_failed":  return "LIFE SUPPORT FUNCTIONS: DEPLETED\n\nWell, this is it, this unforgiving planet has finally bested me, Captain Olimar. I write this final log as a warning to anyone who finds themself on this wretched planet. Leave. Leave and never return. If you don't, you will meet the same fate I have. All the loved ones I have with me at the end are these, my Pikmin... Goodnight...";
        case "adv1_4_failed":  return "LIFE SUPPORT FUNCTIONS: DEPLETED\n\nWell, this is it, this unforgiving planet has finally bested me, Captain Olimar. I write this final log as a warning to anyone who finds themself on this wretched planet. Leave. Leave and never return. If you don't, you will meet the same fate I have. All the loved ones I have with me at the end are these, my Pikmin... Goodnight...";
        case "adv1_5_failed":  return "LIFE SUPPORT FUNCTIONS: DEPLETED\n\nWell, this is it, this unforgiving planet has finally bested me, Captain Olimar. I write this final log as a warning to anyone who finds themself on this wretched planet. Leave. Leave and never return. If you don't, you will meet the same fate I have. All the loved ones I have with me at the end are these, my Pikmin... Goodnight...";
        case "adv1_6_failed":  return "LIFE SUPPORT FUNCTIONS: CRITICAL\n\nThere is no more time for me to stay on this planet. I must depart, leaving some very valuable personal keepsakes on the surface. I write this final log of this voyage knowing that this will not be the last time I visit this planet. I, Captain Olimar, will return with better equipment and more help. My voyaging days are not over just yet, and this will not be the last time I work with these Pikmin.";

        // ========= Home Planet Cultivation Restoration (adv2_*, 7 missions) =========
        case "adv2_1_cleared": return "";
        case "adv2_2_cleared": return "";
        case "adv2_3_cleared": return "";
        case "adv2_4_cleared": return "";
        case "adv2_5_cleared": return "";
        case "adv2_6_cleared": return "";
        // (adv2_7 is the last mission -> fires "adv2_complete", not "_cleared")
        case "adv2_complete":  return "";

        case "adv2_1_failed":  return "";
        case "adv2_2_failed":  return "";
        case "adv2_3_failed":  return "";
        case "adv2_4_failed":  return "";
        case "adv2_5_failed":  return "";
        case "adv2_6_failed":  return "";
        case "adv2_7_failed":  return "";

        // ================ Glutton's Sweet Tooth (adv3_*, 7 missions) ================
        case "adv3_1_cleared": return "";
        case "adv3_2_cleared": return "";
        case "adv3_3_cleared": return "";
        case "adv3_4_cleared": return "";
        case "adv3_5_cleared": return "";
        case "adv3_6_cleared": return "";
        // (adv3_7 is the last mission -> fires "adv3_complete", not "_cleared")
        case "adv3_complete":  return "";

        case "adv3_1_failed":  return "";
        case "adv3_2_failed":  return "";
        case "adv3_3_failed":  return "";
        case "adv3_4_failed":  return "";
        case "adv3_5_failed":  return "";
        case "adv3_6_failed":  return "";
        case "adv3_7_failed":  return "";

        default: return "";   // unknown / nothing written yet -> screen is skipped
    }
}
