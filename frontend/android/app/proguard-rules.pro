# App-specific R8/ProGuard keep rules (referenced from build.gradle.kts).
#
# WorkManager — pulled in transitively by plaid_flutter — initializes at app
# start via androidx.startup. Room instantiates its generated database class
# (androidx.work.impl.WorkDatabase_Impl) REFLECTIVELY through a no-arg
# constructor; R8 can't see that call, strips the constructor, and the app
# crashes instantly at launch with:
#   NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
# Keep the no-arg constructor of every RoomDatabase implementation.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
