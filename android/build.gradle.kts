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
    project.evaluationDependsOn(":app")

    // irondash_engine_context (transitive via super_clipboard) predates AGP's
    // namespace requirement — its build.gradle never sets `namespace`, only the
    // legacy AndroidManifest `package` attribute, which AGP 8+ ignores. Backfill
    // it from that same manifest value here rather than patching the pub-cache
    // copy, which `flutter pub get` overwrites on every CI run.
    afterEvaluate {
        if (project.name == "irondash_engine_context") {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
                ?.let { lib ->
                    if (lib.namespace == null) {
                        lib.namespace = "dev.irondash.engine_context"
                    }
                }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
