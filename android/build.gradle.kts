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

// 各插件的 Java/Kotlin 编译目标各不相同：flutter_js 是 Java 11/Kotlin 1.8，
// android_file_picker 是 Java 17/Kotlin 17。AGP 9 要求同一模块的 Java 与
// Kotlin 目标必须完全相等（三次构建验证：11/1.8、17/11、11/17 全失败），
// 所以不能只统 Kotlin——这里把所有子工程的 Java 和 Kotlin 目标一起提到 17。
// 注意：kotlinOptions 在 KGP 2.4 下是报错级废弃，必须用 compilerOptions DSL。
subprojects {
    tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
