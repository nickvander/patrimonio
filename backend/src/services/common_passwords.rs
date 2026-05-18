//! Embedded blocklist of common breached passwords.
//!
//! Closes audit L3 ("HIBP / breached-password check"). The user
//! already faces a 12-char minimum, so the realistic threat profile
//! is `password12345` / `qwerty1234567` style picks — long enough to
//! pass the length check but still trivially compromised.
//!
//! Approach: embed a curated subset of the SecLists / HIBP top-N
//! lists, filtered down to entries ≥ 12 chars. ~250 entries, sorted
//! alphabetically, binary-searched at validation time. Memory cost
//! ~4 KB of `.rodata`, zero allocations on the validate path.
//!
//! This is intentionally conservative — we are not trying to match
//! HIBP's full 600M-entry corpus. The bloom-filter variant is in the
//! follow-up backlog. The point of this layer is to catch the
//! *embarrassingly common* picks (every variant of `password<digits>`,
//! every popular keyboard walk + suffix) so a casual attacker with
//! a common-password dictionary gets nowhere.
//!
//! Selection criteria:
//!   * Length ≥ 12 (entries shorter than this fail the length check
//!     before we get here).
//!   * Appears in the top 10000 of SecLists' `rockyou-with-counts.txt`
//!     or HIBP's NTLM ordered list.
//!   * Lowercased — we match case-insensitively.
//!
//! The list MUST stay sorted; `is_common_password` uses `binary_search`.

/// Sorted (ASCII order) list of common breached passwords with
/// length ≥ 12. Update by adding new entries in sorted position
/// — `cargo test --lib common_passwords` enforces the invariant.
pub(crate) const COMMON_PASSWORDS: &[&str] = &[
    "000000000000",
    "0000000000000",
    "00000000000000",
    "010203040506",
    "012345678901",
    "0123456789012",
    "01234567890123",
    "100000000000",
    "102938475610",
    "111111111111",
    "1111111111111",
    "11111111111111",
    "121212121212",
    "123123123123",
    "1234567890ab",
    "1234567890abc",
    "1234567890qw",
    "12345password",
    "1234abcd1234",
    "1234qwerty12",
    "1234qwertyuiop",
    "1234zxcv1234",
    "1q2w3e4r5t6y",
    "1q2w3e4r5t6y7u",
    "1qaz2wsx3edc",
    "1qaz2wsx3edc4rfv",
    "1qazxsw23edc",
    "21436587qwer",
    "222222222222",
    "2222222222222",
    "333333333333",
    "555555555555",
    "666666666666",
    "777777777777",
    "888888888888",
    "9876543210ab",
    "999999999999",
    "abcabcabcabc",
    "abcd12345678",
    "abcd1234efgh",
    "abcdef123456",
    "abcdefg12345",
    "abcdefghijkl",
    "abcdefghijklm",
    "abcdefghijklmn",
    "access123456",
    "admin1234567",
    "admin1234admin",
    "adminadmin12",
    "adminadmin123",
    "administrator",
    "adminpassword",
    "amanda123456",
    "andrew123456",
    "angela123456",
    "asdf12345678",
    "asdfasdfasdf",
    "asdfghjkl123",
    "asdfghjkl1234",
    "asdfqwer1234",
    "ashley123456",
    "baseball1234",
    "basketball12",
    "basketball123",
    "batman123456",
    "broncos12345",
    "buster123456",
    "carlos123456",
    "changeme1234",
    "changeme12345",
    "charles12345",
    "charlie12345",
    "chocolate123",
    "computer1234",
    "computer12345",
    "cookie123456",
    "courtney1234",
    "cowboys12345",
    "daniel123456",
    "danielle1234",
    "diamond12345",
    "dolphin12345",
    "dragon123456",
    "elephant1234",
    "fishing12345",
    "football1234",
    "football12345",
    "footballfan1",
    "freedom12345",
    "george123456",
    "ginger123456",
    "gladiator123",
    "godislove123",
    "google123456",
    "harley123456",
    "harrypotter1",
    "hello1234567",
    "hellohello12",
    "ihatemyself123",
    "iloveyou1!1!",
    "iloveyou1234",
    "iloveyou12345",
    "iloveyou2024",
    "ineedmoney12",
    "jasmine12345",
    "jennifer1234",
    "jessica12345",
    "jonathan1234",
    "jordan123456",
    "jordan23forever",
    "joshua123456",
    "junior123456",
    "justinbieber",
    "kennedy12345",
    "killer123456",
    "letmein123456",
    "linkedin1234",
    "linkedin12345",
    "lovelovelove",
    "loveloveylove",
    "macintosh123",
    "maggie123456",
    "marvel123456",
    "master123456",
    "matthew12345",
    "matthew123456",
    "merlin123456",
    "michael12345",
    "michael123456",
    "michelle1234",
    "mickey123456",
    "midnight1234",
    "minecraft123",
    "mommy1234567",
    "money1234567",
    "monkey123456",
    "monster12345",
    "mustang12345",
    "nicholas1234",
    "nicole123456",
    "notmypassword",
    "olivia123456",
    "p@ssw0rd1234",
    "password!@#$",
    "password0000",
    "password0123",
    "password1!1!",
    "password1234",
    "password12345",
    "password123456",
    "password1234567",
    "password2023",
    "password2024",
    "password2025",
    "passwordpassword",
    "patrick12345",
    "pepperpepper",
    "phoenix12345",
    "playstation1",
    "pokemon12345",
    "popcorn12345",
    "princess1234",
    "princess12345",
    "purple123456",
    "qazwsxedcrfv",
    "qazwsxedcrfvtgb",
    "qweasdzxc123",
    "qwertasdfgzx",
    "qwerty123456",
    "qwerty1234567",
    "qwerty12345678",
    "qwertyqwerty",
    "qwertyuiop12",
    "qwertyuiop123",
    "qwertyuiop1234",
    "qwertyuiopasdf",
    "qwertzuiop12",
    "rainbow12345",
    "ranger123456",
    "rangers12345",
    "robert123456",
    "rockstar1234",
    "rootroot1234",
    "samantha1234",
    "scotland1234",
    "secret123456",
    "secretsecret",
    "shadow123456",
    "soccer123456",
    "sophie123456",
    "spiderman123",
    "spongebob123",
    "sunshine1234",
    "superman1234",
    "superman12345",
    "swordfish123",
    "taylor123456",
    "test12345678",
    "testtest1234",
    "thisismypassword",
    "thomas123456",
    "tigger123456",
    "tinkerbell12",
    "trustno123456",
    "turtle123456",
    "victoria1234",
    "welcome12345",
    "welcome123456",
    "welcomehome1",
    "whatever1234",
    "william12345",
    "winter123456",
    "yankees12345",
    "zaq12wsxcde3",
    "zaq1xsw2cde3",
    "zxcvbnm12345",
    "zxcvbnmasdfgh",
];

/// Check whether `password` (case-insensitive) appears in the
/// embedded breach list. Stable across the binary's lifetime — no
/// I/O, no allocation beyond the lowercase clone.
pub fn is_common_password(password: &str) -> bool {
    let lower = password.to_lowercase();
    COMMON_PASSWORDS.binary_search(&lower.as_str()).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The binary_search above is undefined behaviour when the slice
    /// isn't sorted. This test fails the build if a maintainer pastes
    /// a new entry in the wrong place.
    #[test]
    fn list_is_sorted_and_lowercased() {
        for win in COMMON_PASSWORDS.windows(2) {
            assert!(
                win[0] < win[1],
                "common_passwords list out of order at: {:?} -> {:?}",
                win[0],
                win[1]
            );
        }
        for entry in COMMON_PASSWORDS {
            assert_eq!(
                *entry,
                entry.to_lowercase(),
                "common_passwords entry must be lowercase: {entry:?}"
            );
            assert!(
                entry.chars().count() >= 12,
                "common_passwords entry shorter than the 12-char minimum: {entry:?}"
            );
        }
    }

    #[test]
    fn flags_canonical_breaches() {
        assert!(is_common_password("password1234"));
        assert!(is_common_password("Password1234")); // case-insensitive
        assert!(is_common_password("QWERTY123456"));
        assert!(is_common_password("1qaz2wsx3edc"));
    }

    #[test]
    fn passes_strong_passwords() {
        // Random-ish phrases that wouldn't appear in any public
        // breach list. Catches false-positives in the matcher.
        assert!(!is_common_password("correct horse battery staple"));
        assert!(!is_common_password("Tr0ub4dor&3-extra-suffix"));
        assert!(!is_common_password("aurora-fjord-pelican-cordon"));
    }
}
