# R8 rules for the release build.
#
# Flutter, Firebase and the plugins each ship consumer ProGuard rules that R8
# picks up automatically, so this file should stay SMALL — it holds only the
# gaps those don't cover. Anything added here should say why.

# The Flutter engine references Play Core's deferred-components API reflectively
# even when the app never uses deferred components, so R8 sees the references
# without the classes on the classpath. We don't ship split/deferred components,
# so warning about them is noise, not a missing dependency.
-dontwarn com.google.android.play.core.**
