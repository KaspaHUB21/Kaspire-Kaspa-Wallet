allprojects {
    repositories {
        google()
        mavenCentral()
        // Reown WalletKit's walletconnect_pay plugin ships Yttrium through JitPack.
        maven("https://jitpack.io")
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)
subprojects {
    project.layout.buildDirectory.value(newBuildDir.dir(project.name))
}
tasks.register<Delete>("clean") { delete(rootProject.layout.buildDirectory) }
