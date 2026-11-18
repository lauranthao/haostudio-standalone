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
subprojects {
    project.evaluationDependsOn(":app")
}

// flutter_js（0.8.7）等插件在自己的 android/build.gradle 里把 Kotlin 编译目标
// 写死成 1.8，而工程的 Java 编译目标是 11；AGP 9 要求 Kotlin 目标不低于 Java
// 目标，否则打包失败。这里统一把所有子工程的 Kotlin 编译目标提到 17：
// 既盖住 Java 11 的插件，也不动本身就是 17 的插件（android_file_picker）。
// 注意：kotlinOptions 在 KGP 2.4 下是报错级废弃，必须用 compilerOptions DSL。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
