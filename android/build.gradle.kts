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
// Kotlin 目标必须完全相等（四次构建验证：11/1.8、17/11、11/17、11/17 全失败），
// 所以不能只统一个。注意：Java 目标必须在配置完成后统一——构建工具在配置
// 阶段会把 android.compileOptions 的值写回 Java 编译任务，直接配会被它后来
// 覆盖掉（构建 #8 的教训）；Kotlin 那边用 compilerOptions 是显式设置，不会被
// 覆盖。kotlinOptions 在 KGP 2.4 下是报错级废弃，必须用 compilerOptions DSL。
// 另注意：有的子工程（:app）在执行到这里时已经被评估过，对它们直接配，
// 不能再调 afterEvaluate，否则 Gradle 直接报错（构建 #9 的教训）。
subprojects {
    if (state.executed) {
        tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
            sourceCompatibility = "17"
            targetCompatibility = "17"
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    } else {
        afterEvaluate {
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
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
