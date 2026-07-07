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
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 一部プラグイン (onnxruntime 等) は compileSdk 33 固定でビルドされるが、その
// 推移依存の androidx は compileSdk 34+ を要求する。全 Android サブプロジェクトの
// compileSdk を底上げして解消する (Flutter 定番の対処)。
// evaluationDependsOn(":app") が :app を先行評価するため、afterEvaluate の登録は
// その前に済ませる (でないと "already evaluated" で失敗)。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            val current = androidExt.compileSdkVersion
                ?.removePrefix("android-")
                ?.toIntOrNull() ?: 0
            if (current < 34) {
                androidExt.compileSdkVersion(36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
