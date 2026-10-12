// Top-level build file. Plugins are declared here with `apply false` so the
// version catalog stays the single source of truth for every module.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.ksp) apply false
}
