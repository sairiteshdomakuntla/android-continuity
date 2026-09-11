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

subprojects {
    val configureCompileSdk: Project.() -> Unit = {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            val targetCompileSdk = 36
            val methods = androidExt.javaClass.methods
            val compileMethod = methods.firstOrNull { m ->
                (m.name == "compileSdkVersion" || m.name == "setCompileSdkVersion" || m.name == "setCompileSdk") &&
                    m.parameterTypes.size == 1 &&
                    (m.parameterTypes[0] == Int::class.javaPrimitiveType || m.parameterTypes[0] == java.lang.Integer::class.java)
            }
            try {
                compileMethod?.invoke(androidExt, targetCompileSdk)
            } catch (_: Throwable) {}
        }
    }

    if (state.executed) {
        configureCompileSdk()
    } else {
        afterEvaluate {
            configureCompileSdk()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
