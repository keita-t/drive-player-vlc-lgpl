plugins {
    alias(libs.plugins.android.library)
    `maven-publish`
}

// Both given by ./local_build.sh --build-libvlc: what build-native.sh left (its out/ directory, with
// bindings/ and jni/), and the repository directory to publish into.
val nativeOutput: File = file(providers.gradleProperty("libvlc.nativeOutput").get())
val repository: File = file(providers.gradleProperty("libvlc.repository").get())
val coordinates = libs.libvlc.lgpl.get()

android {
    // The bindings' own package: their sources import org.videolan.BuildConfig and org.videolan.R.
    namespace = "org.videolan"
    compileSdk = 36

    defaultConfig {
        // The API level the native libraries are built against (build-native.sh).
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }
    buildFeatures {
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    sourceSets.getByName("main") {
        java.srcDir(nativeOutput.resolve("bindings/src"))
        res.srcDir(nativeOutput.resolve("bindings/res"))
        jniLibs.srcDir(nativeOutput.resolve("jni"))
    }

    packaging {
        jniLibs {
            // build-native.sh strips the libraries it hands over; packaged as they are.
            keepDebugSymbols += "**/*.so"
        }
    }

    publishing {
        singleVariant("release")
    }
}

// The one source of the bindings published under the GNU GPL, and of no use without the renderer
// modules and stream output this build leaves out. Its native half is removed by
// patches/libvlcjni/0001-build-the-bindings-without-the-renderer-discoverer.patch.
tasks.withType<JavaCompile>().configureEach {
    exclude("org/videolan/libvlc/RendererDiscoverer.java")
}

dependencies {
    // What the bindings' sources import, at the lowest versions libvlcjni itself builds with:
    // upstream asks for androidx.annotation 1.7.1 and for legacy-support-v4 1.0.0, of which the
    // sources kept here use androidx.core and lifecycle-livedata-core. The app's own versions win.
    api("androidx.annotation:annotation:1.7.1")
    implementation("androidx.core:core:1.0.0")
    implementation("androidx.lifecycle:lifecycle-livedata-core:2.0.0")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = coordinates.module.group
            artifactId = coordinates.module.name
            version = coordinates.versionConstraint.requiredVersion
            afterEvaluate {
                from(components["release"])
            }
            pom {
                name.set("libVLC for Android (Drive Player build)")
                description.set(
                    "libVLC and its libvlcjni bindings, built by Drive Player from VideoLAN's sources " +
                        "under the GNU LGPL 2.1 only, for arm64-v8a.",
                )
                licenses {
                    license {
                        name.set("GNU Lesser General Public License, version 2.1")
                        url.set("https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")
                    }
                }
            }
        }
    }
    repositories {
        maven {
            name = "selfBuilt"
            url = uri(repository)
        }
    }
}
