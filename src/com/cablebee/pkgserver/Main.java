package com.cablebee.pkgserver;

/**
 * Entry point for app_process.
 *
 * Usage:
 *   app_process /system/bin com.cablebee.pkgserver.Main [packageName]
 *
 * With no args  → dump ALL packages, one JSON per line on stdout
 * With one arg  → dump that single package only
 *
 * Each line:
 *   {"package":"com.foo","label":"Foo","icon":"<base64-png>","apkPath":"...","apkSize":123,
 *    "enabled":true,"flags":0,"versionCode":1,"versionName":"1.0",
 *    "firstInstallTime":0,"lastUpdateTime":0,"dataDir":"/data/data/com.foo",
 *    "minSdkVersion":21,"targetSdkVersion":33}
 *
 * Error line (package not found / exception):
 *   {"package":"com.foo","error":"message"}
 */
public class Main {
    public static void main(String[] args) {
        try {
            PackageServer server = new PackageServer();
            if (args.length >= 1) {
                server.dumpPackage(args[0]);
            } else {
                server.dumpAll();
            }
        } catch (Throwable t) {
            System.err.println("fatal: " + t.getMessage());
            t.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
