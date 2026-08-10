//! euspinolia — çekirdek Zig katmanı.
//!
//! Faz 0: burada henüz veri yapısı yok. Amaç sadece C ABI üzerinden
//! Python'un bu kütüphaneyi yükleyip fonksiyon çağırabildiğini doğrulamak.
//! Dışa açılan her sembol `eus_` önekini taşır.

const std = @import("std");

/// Kütüphane sürümü. Python tarafı bunu okuyarak yüklediği .so'nun
/// beklediği sürüm olup olmadığını kontrol edebilir.
const version_string: [:0]const u8 = "0.0.1";

/// FFI köprüsünün ayakta olduğunu gösteren sabit imza değeri ("EUS" leet).
/// Yanlış kütüphaneyi yüklediğimizde bu değer tutmaz.
pub const magic: i32 = 0xE05;

/// En basit canlılık testi: argümansız çağrı, sabit dönüş.
export fn eus_ping() i32 {
    return magic;
}

/// Argüman geçişini doğrular: iki i64 alıp toplamını döner.
/// Taşma durumunda sarmalar (wrapping) — Faz 0 için yeterli.
export fn eus_add(a: i64, b: i64) i64 {
    return a +% b;
}

/// Null ile sonlanan sürüm dizgisi. Bellek statik, çağıran taraf serbest bırakmaz.
export fn eus_version() [*:0]const u8 {
    return version_string.ptr;
}

test "ping sabit imzayı döner" {
    try std.testing.expectEqual(magic, eus_ping());
}

test "add temel aritmetik" {
    try std.testing.expectEqual(@as(i64, 7), eus_add(3, 4));
    try std.testing.expectEqual(@as(i64, -1), eus_add(-4, 3));
}

test "add taşmada sarmalar" {
    try std.testing.expectEqual(std.math.minInt(i64), eus_add(std.math.maxInt(i64), 1));
}

test "version okunabilir bir dizgi" {
    const v = std.mem.span(eus_version());
    try std.testing.expectEqualStrings("0.0.1", v);
}
