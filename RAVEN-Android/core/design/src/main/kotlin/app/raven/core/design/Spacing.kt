package app.raven.core.design

import androidx.compose.ui.unit.dp

/**
 * 8-point grid spacing tokens. One-to-one mirror of the iOS
 * `DS.space*` ladder declared in
 * `ios-native/RAVEN/RAVEN/Views/Components/RavenDesignTokens.swift`.
 *
 * Stick to these named values; if you find yourself reaching for an
 * arbitrary `12.dp` somewhere, prefer either a named token or document
 * the deviation. The iOS app holds the line on this and the Android UI
 * needs to feel identical at the pixel level.
 */
object Spacing {
    val xxs = 4.dp   // DS.space4   — gap inside tight badges / chip rows
    val xs  = 8.dp   // DS.space8   — between icon + label
    val sm  = 12.dp  // DS.space12  — small inset
    val md  = 16.dp  // DS.space16  — card padding, list-row padding
    val lg  = 24.dp  // DS.space24  — section gap
    val xl  = 32.dp  // DS.space32  — screen edge top/bottom for hero
}
