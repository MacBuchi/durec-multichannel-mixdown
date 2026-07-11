//! iXML metadata parsing (track names / interleave order).
//!
//! DUREC embeds an iXML chunk describing each recorded track. The chunk is
//! frequently padded with NUL bytes or preceded by junk, so the payload is
//! cleaned before parsing.

use quick_xml::events::Event;
use quick_xml::Reader;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackInfo {
    /// 1-based interleave index (channel position in the WAV file).
    pub index: u32,
    pub name: String,
}

/// Strip everything before `<?xml` and remove control characters (keeping
/// tab/newline and all valid UTF-8 text, unlike the old Python tool which
/// destroyed non-ASCII track names).
pub fn clean_xml(data: &str) -> String {
    let Some(start) = data.find("<?xml") else {
        return String::new();
    };
    data[start..]
        .chars()
        .filter(|c| !c.is_control() || *c == '\t' || *c == '\n' || *c == '\r')
        .collect::<String>()
        .trim()
        .to_string()
}

/// Parse a (cleaned or raw) iXML string into track descriptors, sorted by
/// interleave index. Returns an empty list for missing/malformed XML.
pub fn parse_tracks(ixml: &str) -> Vec<TrackInfo> {
    let cleaned = clean_xml(ixml);
    if cleaned.is_empty() {
        return Vec::new();
    }

    let mut reader = Reader::from_str(&cleaned);
    reader.config_mut().trim_text(true);

    let mut tracks: Vec<TrackInfo> = Vec::new();
    let mut in_track = false;
    let mut current_tag: Option<String> = None;
    let mut name: Option<String> = None;
    let mut index: Option<u32> = None;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let tag = String::from_utf8_lossy(e.name().as_ref()).to_string();
                if tag == "TRACK" {
                    in_track = true;
                    name = None;
                    index = None;
                } else if in_track {
                    current_tag = Some(tag);
                }
            }
            Ok(Event::Text(t)) => {
                if in_track {
                    if let Ok(text) = t.decode() {
                        match current_tag.as_deref() {
                            Some("NAME") => name = Some(text.into_owned()),
                            Some("INTERLEAVE_INDEX") => index = text.trim().parse().ok(),
                            _ => {}
                        }
                    }
                }
            }
            Ok(Event::End(e)) => {
                let tag = e.name();
                if tag.as_ref() == b"TRACK" {
                    if let Some(idx) = index {
                        tracks.push(TrackInfo {
                            index: idx,
                            name: name.take().unwrap_or_else(|| "Unknown".to_string()),
                        });
                    }
                    in_track = false;
                } else {
                    current_tag = None;
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => return Vec::new(),
            _ => {}
        }
    }

    tracks.sort_by_key(|t| t.index);
    tracks
}

/// Initial pan position for a track name: names ending in " L" / " R" are
/// panned hard left/right (stereo pairs), everything else centred.
/// Pan range is -1.0 (left) .. +1.0 (right).
pub fn default_pan_for_name(name: &str) -> f64 {
    if name.ends_with(" L") {
        -1.0
    } else if name.ends_with(" R") {
        1.0
    } else {
        0.0
    }
}

/// Detect the partner of a stereo pair: "Drums OH L" ↔ "Drums OH R".
pub fn stereo_pair_base(name: &str) -> Option<&str> {
    name.strip_suffix(" L").or_else(|| name.strip_suffix(" R"))
}
