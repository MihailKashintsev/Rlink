allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// CargoKit (vendored inside super_native_extensions, a transitive dep of
// super_clipboard) has a real bug in its plugin.gradle: it iterates
// Project.childProjects (a Map) with `for (project in projects)`, which in
// Groovy yields Map.Entry objects, then calls `project.childProjects` on that
// entry directly instead of `project.value.childProjects` — fails under this
// Gradle version with "No such property: childProjects for class:
// java.util.HashMap$Node". The vendored copy lives in the pub-cache and gets
// overwritten by every `flutter pub get`, so patch it here on every build
// instead of hand-editing pub-cache (which CI re-fetches from scratch).
run {
    val pubCache = System.getenv("PUB_CACHE")
        ?: "${System.getProperty("user.home")}/.pub-cache"
    file("$pubCache/hosted/pub.dev")
        .listFiles { f -> f.isDirectory && f.name.startsWith("super_native_extensions-") }
        ?.forEach { pkgDir ->
            val script = pkgDir.resolve("cargokit/gradle/plugin.gradle")
            if (script.exists()) {
                val text = script.readText()
                val fixed = text.replace(
                    "return _findFlutterPlugin(project.childProjects);",
                    "return _findFlutterPlugin(project.value.childProjects);"
                )
                if (fixed != text) script.writeText(fixed)
            }
        }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.set(newBuildDir)

// Transitive deps of super_clipboard whose build.gradle predates AGP's
// namespace requirement — they only declare the legacy AndroidManifest
// `package` attribute, which AGP 8+ ignores. Backfilled below from that same
// manifest value rather than patching the pub-cache copy, which
// `flutter pub get` overwrites on every CI run.
val missingNamespaces = mapOf(
    "irondash_engine_context" to "dev.irondash.engine_context",
    "super_native_extensions" to "com.superlist.super_native_extensions",
)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.set(newSubprojectBuildDir)

    // plugins.withId (not afterEvaluate) since evaluationDependsOn below can
    // force this project to evaluate before an afterEvaluate block registers.
    missingNamespaces[project.name]?.let { ns ->
        plugins.withId("com.android.library") {
            extensions.configure(com.android.build.gradle.LibraryExtension::class.java) {
                if (namespace == null) {
                    namespace = ns
                }
            }
        }
    }

    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
