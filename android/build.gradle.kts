allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.set(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.set(newSubprojectBuildDir)

    // irondash_engine_context (transitive via super_clipboard) predates AGP's
    // namespace requirement — its build.gradle never sets `namespace`, only the
    // legacy AndroidManifest `package` attribute, which AGP 8+ ignores. Backfill
    // it from that same manifest value here rather than patching the pub-cache
    // copy, which `flutter pub get` overwrites on every CI run. Uses
    // plugins.withId (not afterEvaluate) since evaluationDependsOn below can
    // force this project to evaluate before an afterEvaluate block registers.
    if (project.name == "irondash_engine_context") {
        plugins.withId("com.android.library") {
            extensions.configure(com.android.build.gradle.LibraryExtension::class.java) {
                if (namespace == null) {
                    namespace = "dev.irondash.engine_context"
                }
            }
        }
    }

    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
