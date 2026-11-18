import org.gradle.kotlin.dsl.withGroovyBuilder

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
// Kotlin 目标必须完全相等（五次构建验证：11/1.8、17/11、11/17、11/17、11/17
// 全失败），所以不能只统一个。注意：Java 目标不能只改编译任务——构建工具
// 在配置阶段会把 android.compileOptions 的值写回 Java 编译任务，直接改任务
// 会被它后来覆盖掉（构建 #8、#10 的教训）；所以这里直接改 compileOptions
// 这个源头（用 GroovyBuilder 是因为 Kotlin DSL 里 kotlinOptions 相关写法
// 已被废弃）。Kotlin 那边用 compilerOptions 是显式设置，已被验证有效，
// 不会被覆盖。kotlinOptions 在 KGP 2.4 下是报错级废弃，必须用
// compilerOptions DSL。
// 另注意：有的子工程（:app）在执行到这里时已经被评估过，对它们直接配，
// 不能再调 afterEvaluate，否则 Gradle 直接报错（构建 #9 的教训）。
subprojects {
    plugins.withId("com.android.library") {
        (extensions.getByName("android") as groovy.lang.GroovyObject).withGroovyBuilder {
            "compileOptions" {
                setProperty("sourceCompatibility", JavaVersion.VERSION_17)
                setProperty("targetCompatibility", JavaVersion.VERSION_17)
            }
        }
    }
    // :app 不在这里改——它自己的 app/build.gradle.kts 里已经是
    // compileOptions 17 + Kotlin 17（Flutter 3.47 模板自带），
    // 到这里时它的值已被 finalized，再改会直接报错（构建 #11 的教训）。
    // 有的插件在自己的构建文件里后写 compileOptions（screen_brightness_android
    // 写死 1.8），会盖掉上面 withId 时设的值，所以这里在配置完成后再设一次
    // compileOptions——此时各插件自己的脚本已跑完，而构建工具还没读这个值去配
    // Java 编译任务（构建 #12 的教训）。:app 在执行到这里时已被评估过，跳过
    // 它（它自己的文件里已是 17/17）。
    if (!state.executed) {
        afterEvaluate {
            (extensions.findByName("android") as? groovy.lang.GroovyObject)?.let { androidExt ->
                androidExt.withGroovyBuilder {
                    "compileOptions" {
                        setProperty("sourceCompatibility", JavaVersion.VERSION_17)
                        setProperty("targetCompatibility", JavaVersion.VERSION_17)
                    }
                }
            }
        }
    }
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
