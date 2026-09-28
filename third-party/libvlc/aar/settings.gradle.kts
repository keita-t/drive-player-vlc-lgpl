// Packages Drive Player's own libVLC — the native libraries third-party/libvlc/build-native.sh
// builds and the libvlcjni bindings they come with — as an Android library, and publishes it to the
// local repository the app's build resolves it from. A build of its own, not a project of the app's:
// it runs once per libVLC build (./local_build.sh --build-libvlc), and the app consumes its result
// as a published artifact, the same way it consumed VideoLAN's.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
    // The app's catalog, so the library is built with the app's Android Gradle Plugin and
    // published under the coordinates the app depends on.
    versionCatalogs {
        create("libs") {
            from(files("../../../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "libvlc-lgpl"
