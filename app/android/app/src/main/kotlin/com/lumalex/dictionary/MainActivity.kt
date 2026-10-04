package com.lumalex.dictionary

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.speech.tts.TextToSpeech
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Android's Storage Access Framework owns every external-dictionary grant.
 * Flutter and Rust never receive broad storage permission. MDX files use a
 * private validated performance copy; large MDD media volumes remain lazy.
 */
open class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL_NAME = "local_dictionary/file_access"
        const val TEXT_TO_SPEECH_CHANNEL_NAME = "local_dictionary/text_to_speech"
        const val READER_MEMORY_CHANNEL_NAME = "local_dictionary/reader_memory"
        const val APP_DIAGNOSTICS_CHANNEL_NAME = "local_dictionary/app_diagnostics"
        const val PICK_DICTIONARY_FOLDER_REQUEST = 0x4C58
        const val READ_PERMISSION_FLAGS = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }

    private var pendingFolderResult: MethodChannel.Result? = null
    private val openDescriptors = ConcurrentHashMap<String, ParcelFileDescriptor>()
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler(::handleFileAccessCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TEXT_TO_SPEECH_CHANNEL_NAME)
            .setMethodCallHandler(::handleTextToSpeechCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, READER_MEMORY_CHANNEL_NAME)
            .setMethodCallHandler(::handleReaderMemoryCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_DIAGNOSTICS_CHANNEL_NAME)
            .setMethodCallHandler(::handleAppDiagnosticsCall)
        initializeTextToSpeech()
    }

    @SuppressLint("WebViewApiAvailability")
    private fun handleAppDiagnosticsCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getRuntimeDiagnostics") {
            result.notImplemented()
            return
        }
        // Directory sizes can involve many persistent index files. Keep that
        // traversal away from Flutter's platform thread so opening the sheet
        // never stalls an active article.
        Thread {
            try {
                val packageInfo = packageManager.getPackageInfo(packageName, 0)
                val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                val diagnostics = mapOf(
                    "versionName" to (packageInfo.versionName ?: "unknown"),
                    "versionCode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        packageInfo.longVersionCode.toString()
                    } else {
                        @Suppress("DEPRECATION")
                        packageInfo.versionCode.toString()
                    },
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "device" to listOf(Build.MANUFACTURER, Build.MODEL)
                        .filter { it.isNotBlank() }
                        .joinToString(" "),
                    "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
                    "webViewVersion" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        WebView.getCurrentWebViewPackage()?.versionName ?: "unavailable"
                    } else {
                        "unavailable"
                    },
                    "memoryClassMb" to activityManager.memoryClass,
                    "isLowRamDevice" to activityManager.isLowRamDevice,
                    "stagedDictionaryBytes" to directorySize(File(filesDir, "saf-staging")),
                    "indexBytes" to directorySize(File(filesDir, "key-indexes")),
                )
                runOnUiThread { result.success(diagnostics) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "diagnostics_failed",
                        "Unable to read Android runtime diagnostics: ${error.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun directorySize(directory: File): Long {
        if (!directory.exists()) return 0
        return directory.walkTopDown()
            .filter { it.isFile }
            .fold(0L) { total, file -> total + file.length() }
    }

    private fun handleReaderMemoryCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getMemoryProfile") {
            result.notImplemented()
            return
        }
        val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        result.success(
            mapOf(
                "memoryClassMb" to activityManager.memoryClass,
                "isLowRamDevice" to activityManager.isLowRamDevice,
            ),
        )
    }

    private fun handleFileAccessCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDictionaryFolder" -> launchDictionaryFolderPicker(result)
            "scanDictionaryFolder" -> scanPersistedDictionaryFolder(call, result)
            "hasReadGrant" -> hasReadGrant(call, result)
            "openReadHandle" -> openReadHandle(call, result)
            "closeReadHandle" -> closeReadHandle(call, result)
            "removeLocalCopy" -> removeLocalCopy(call, result)
            else -> result.notImplemented()
        }
    }

    private fun initializeTextToSpeech() {
        textToSpeech?.shutdown()
        textToSpeechReady = false
        textToSpeech = TextToSpeech(applicationContext) { status ->
            textToSpeechReady = status == TextToSpeech.SUCCESS
        }
    }

    private fun handleTextToSpeechCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "speak" -> speakText(call, result)
            "stop" -> {
                textToSpeech?.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun speakText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim()
        val languageTag = call.argument<String>("locale")
        if (text.isNullOrEmpty()) {
            result.error("invalid_text", "A non-empty example sentence is required.", null)
            return
        }
        val engine = textToSpeech
        if (!textToSpeechReady || engine == null) {
            result.error(
                "tts_unavailable",
                "系统英语语音尚未就绪，请稍后重试或安装英语文字转语音语音包。",
                null,
            )
            return
        }

        val requestedLocale = languageTag?.let(Locale::forLanguageTag) ?: Locale.US
        val requestedStatus = engine.setLanguage(requestedLocale)
        val usable = requestedStatus != TextToSpeech.LANG_MISSING_DATA &&
            requestedStatus != TextToSpeech.LANG_NOT_SUPPORTED
        if (!usable) {
            val fallbackStatus = engine.setLanguage(Locale.US)
            if (fallbackStatus == TextToSpeech.LANG_MISSING_DATA ||
                fallbackStatus == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                result.error(
                    "language_missing",
                    "未安装可用的英语文字转语音语音包。",
                    null,
                )
                return
            }
        }

        val status = engine.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "lumalex-example-${System.nanoTime()}",
        )
        if (status != TextToSpeech.SUCCESS) {
            result.error("speech_failed", "系统英语语音无法开始播放。", null)
            return
        }
        result.success(true)
    }

    private fun launchDictionaryFolderPicker(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("picker_active", "A dictionary folder picker is already open.", null)
            return
        }
        pendingFolderResult = result
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            },
            PICK_DICTIONARY_FOLDER_REQUEST,
        )
    }

    @Deprecated("Deprecated in Android API 30")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_DICTIONARY_FOLDER_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        val treeUri = data?.data
        if (resultCode != RESULT_OK || treeUri == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                treeUri,
                (data?.flags ?: 0) and READ_PERMISSION_FLAGS,
            )
        } catch (_: SecurityException) {
            result.error("permission_denied", "Android could not retain folder read access.", null)
            return
        }

        Thread {
            try {
                val dictionaries = scanDictionaryTree(treeUri)
                runOnUiThread {
                    result.success(
                        mapOf(
                            "accessPath" to treeUri.toString(),
                            "dictionaries" to dictionaries,
                        ),
                    )
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "scan_failed",
                        "Unable to scan the selected dictionary folder: ${error.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun hasReadGrant(call: MethodCall, result: MethodChannel.Result) {
        val rawUri = call.argument<String>("uri")
        val uri = rawUri?.let(Uri::parse)
        if (uri == null) {
            result.success(false)
            return
        }
        result.success(
            contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission
            },
        )
    }

    /**
     * Re-enumerates a previously approved folder without reopening Android's
     * picker. This lets newer app builds recover numbered MDD volumes omitted
     * by an older import record.
     */
    private fun scanPersistedDictionaryFolder(call: MethodCall, result: MethodChannel.Result) {
        val rawUri = call.argument<String>("accessPath")
        val treeUri = rawUri?.let(Uri::parse)
        if (treeUri == null) {
            result.error("invalid_uri", "A dictionary folder URI is required.", null)
            return
        }
        if (!contentResolver.persistedUriPermissions.any {
                it.uri == treeUri && it.isReadPermission
            }) {
            result.error("permission_denied", "The dictionary folder grant is no longer available.", null)
            return
        }
        Thread {
            try {
                val dictionaries = scanDictionaryTree(treeUri)
                runOnUiThread { result.success(dictionaries) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "scan_failed",
                        "Unable to scan the selected dictionary folder: ${error.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun openReadHandle(call: MethodCall, result: MethodChannel.Result) {
        val rawUri = call.argument<String>("uri")
        val uri = rawUri?.let(Uri::parse)
        val preferLocalCopy = call.argument<Boolean>("preferLocalCopy") == true
        if (uri == null) {
            result.error("invalid_uri", "A readable dictionary URI is required.", null)
            return
        }
        // Content providers may do network, FUSE, or full-file copy work while
        // opening a document. Never perform that work on Flutter's platform
        // thread: it would freeze the progress dialog and the first lookup.
        Thread {
            try {
                val prepared = prepareReadHandle(uri, rawUri, preferLocalCopy)
                runOnUiThread { result.success(prepared) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "open_failed",
                        "Android could not prepare this dictionary document: ${error.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun prepareReadHandle(
        uri: Uri,
        rawUri: String,
        preferLocalCopy: Boolean,
    ): Map<String, Any> {
        val name = documentName(uri)
        if (preferLocalCopy) {
            val staged = materializeDocument(uri, rawUri)
            return mapOf(
                "path" to staged.absolutePath,
                "name" to name,
                "staged" to true,
            )
        }

        openDescriptors[rawUri]?.let { existing ->
            val existingPath = "/proc/self/fd/${existing.fd}"
            if (canReopenForRandomAccess(existingPath)) {
                return mapOf(
                    "path" to existingPath,
                    "name" to name,
                    "staged" to false,
                )
            }
            if (openDescriptors.remove(rawUri, existing)) {
                existing.close()
            }
        }
        val descriptor = contentResolver.openFileDescriptor(uri, "r")
            ?: throw IllegalStateException("Android could not open this dictionary document.")
        val descriptorPath = "/proc/self/fd/${descriptor.fd}"
        if (!canReopenForRandomAccess(descriptorPath)) {
            descriptor.close()
            val staged = materializeDocument(uri, rawUri)
            return mapOf(
                "path" to staged.absolutePath,
                "name" to name,
                "staged" to true,
            )
        }
        val retained = openDescriptors.putIfAbsent(rawUri, descriptor)
        if (retained != null) {
            descriptor.close()
            return mapOf(
                "path" to "/proc/self/fd/${retained.fd}",
                "name" to name,
                "staged" to false,
            )
        }
        return mapOf(
            "path" to descriptorPath,
            "name" to name,
            "staged" to false,
        )
    }

    /**
     * Some DocumentsProvider implementations on physical devices expose an
     * approved document as a pipe. That is valid for sequential reads, but an
     * MDX reader needs seekable offsets throughout the file. Reopening the
     * descriptor through /proc performs the same operation Rust later uses,
     * so this is a small, provider-agnostic capability check.
     */
    private fun canReopenForRandomAccess(path: String): Boolean {
        return try {
            RandomAccessFile(path, "r").use { file ->
                val length = file.length()
                if (length <= 0) return false
                file.seek(0)
                file.read() >= 0
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Materializes a SAF document into a stable app-private file. The same URI
     * reuses the copy while its provider size/timestamp still match, so startup
     * never copies a multi-hundred-megabyte MDX again. Original files are never
     * modified.
     */
    private fun materializeDocument(
        uri: Uri,
        documentUri: String,
    ): File {
        val stagingDirectory = File(filesDir, "saf-staging").apply { mkdirs() }
        if (!stagingDirectory.isDirectory) {
            throw IllegalStateException("The private dictionary cache is unavailable.")
        }
        val staged = stagedFileFor(documentUri)
        if (!documentExists(uri)) {
            staged.delete()
            throw FileNotFoundException(
                "The original dictionary document no longer exists.",
            )
        }
        val sourceSize = documentSize(uri)
        val sourceModifiedMillis = documentLastModified(uri)
        val sizeMatches = sourceSize == null || staged.length() == sourceSize
        val timestampMatches = sourceModifiedMillis == null ||
            staged.lastModified() == sourceModifiedMillis
        if (staged.isFile && sizeMatches && timestampMatches) {
            return staged
        }

        val temporary = File(stagingDirectory, "${staged.name}-${System.nanoTime()}.part")
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                BufferedInputStream(input).use { bufferedInput ->
                    BufferedOutputStream(FileOutputStream(temporary)).use { output ->
                        bufferedInput.copyTo(output)
                    }
                }
            } ?: throw IllegalStateException("Android could not stream this dictionary document.")
            if (staged.exists() && !staged.delete()) {
                throw IllegalStateException("The previous staged dictionary could not be replaced.")
            }
            if (!temporary.renameTo(staged)) {
                throw IllegalStateException("The staged dictionary could not be finalized.")
            }
            if (sourceModifiedMillis != null && sourceModifiedMillis > 0) {
                staged.setLastModified(sourceModifiedMillis)
            }
            return staged
        } catch (error: Exception) {
            temporary.delete()
            staged.delete()
            throw error
        }
    }

    private fun stagedFileFor(documentUri: String): File {
        val stagingDirectory = File(filesDir, "saf-staging")
        val key = MessageDigest.getInstance("SHA-256")
            .digest(documentUri.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        return File(stagingDirectory, "$key.document")
    }

    private fun documentSize(uri: Uri): Long? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getLong(index).takeIf { it >= 0 }
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * A private performance copy is only a cache, never an independent
     * dictionary source. Verify that the provider still exposes the original
     * document before reusing the copy; otherwise a deleted MDX would survive
     * indefinitely as a ghost dictionary inside the app sandbox.
     */
    private fun documentExists(uri: Uri): Boolean {
        return try {
            contentResolver.query(
                uri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { cursor -> cursor.moveToFirst() } == true
        } catch (_: Exception) {
            false
        }
    }

    private fun closeReadHandle(call: MethodCall, result: MethodChannel.Result) {
        call.argument<String>("uri")?.let { uri ->
            openDescriptors.remove(uri)?.close()
        }
        result.success(null)
    }

    private fun removeLocalCopy(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")
        if (uri != null) {
            stagedFileFor(uri).delete()
        }
        result.success(null)
    }

    private fun scanDictionaryTree(treeUri: Uri): List<Map<String, Any>> {
        val documents = mutableListOf<TreeDocument>()
        scanChildren(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
            emptyList(),
            documents,
        )
        val byParent = documents.groupBy { it.parentId }
        val mdxDocuments = documents
            .filter { it.name.endsWith(".mdx", ignoreCase = true) }
        val mdxFolders = mdxDocuments
            .map { it.relativePath.dropLast(1) }
            .distinct()
        return mdxDocuments
            .asSequence()
            .sortedBy { it.name.lowercase(Locale.ROOT) }
            .map { mdx ->
                val baseName = mdx.name.substringBeforeLast('.', mdx.name)
                val mddUris = byParent[mdx.parentId]
                    .orEmpty()
                    .mapNotNull { candidate ->
                        mddVolumeOrder(candidate.name, baseName)?.let { order -> order to candidate.uri }
                    }
                    .sortedBy { it.first }
                    .map { it.second.toString() }
                val sourceFolder = mdx.relativePath.dropLast(1)
                val sidecarResources = documents
                    .asSequence()
                    .filter { candidate ->
                        candidate.relativePath.size > sourceFolder.size &&
                            candidate.relativePath.take(sourceFolder.size) == sourceFolder &&
                            mdxFolders.none { otherFolder ->
                                otherFolder.size > sourceFolder.size &&
                                    candidate.relativePath.size > otherFolder.size &&
                                    candidate.relativePath.take(otherFolder.size) == otherFolder
                            }
                    }
                    .filter { candidate -> isPublisherSidecar(candidate.name) }
                    .map { candidate ->
                        mapOf(
                            "uri" to candidate.uri.toString(),
                            "relativePath" to candidate.relativePath
                                .drop(sourceFolder.size)
                                .joinToString("/"),
                        )
                    }
                    .sortedBy { resource ->
                        (resource["relativePath"] as String).lowercase(Locale.ROOT)
                    }
                    .toList()
                mapOf(
                    "mdxPath" to mdx.uri.toString(),
                    "relativePath" to mdx.relativePath.joinToString("/"),
                    "sourceVersion" to (mdx.sourceVersion ?: ""),
                    "mddPaths" to mddUris,
                    "sidecarResources" to sidecarResources,
                )
            }
            .toList()
    }

    private fun scanChildren(
        treeUri: Uri,
        parentDocumentId: String,
        relativeParentPath: List<String>,
        documents: MutableList<TreeDocument>,
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val typeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(idIndex)
                val name = cursor.getString(nameIndex) ?: continue
                val mimeType = cursor.getString(typeIndex)
                val relativePath = relativeParentPath + name
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    scanChildren(treeUri, documentId, relativePath, documents)
                } else if (isDictionarySourceFile(name)) {
                    // Do not retain every image, audio clip, or unrelated
                    // document while scanning a large user-selected folder.
                    // Only MDX/MDD files and CSS/script/font sidecars can
                    // affect import pairing or rendering.
                    documents.add(
                        TreeDocument(
                            parentId = parentDocumentId,
                            name = name,
                            uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId),
                            relativePath = relativePath,
                            size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null,
                            modifiedMillis = if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) cursor.getLong(modifiedIndex) else null,
                        ),
                    )
                }
            }
        }
    }

    private fun mddVolumeOrder(name: String, mdxBaseName: String): Int? {
        if (!name.endsWith(".mdd", ignoreCase = true)) return null
        val stem = name.substringBeforeLast('.', name)
        if (stem.equals(mdxBaseName, ignoreCase = true)) return 0
        val prefix = "$mdxBaseName."
        if (!stem.startsWith(prefix, ignoreCase = true)) return null
        return stem.substring(prefix.length).toIntOrNull()?.plus(1)
    }

    private fun isPublisherSidecar(name: String): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return extension in setOf("css", "js", "otf", "ttf", "woff", "woff2")
    }

    private fun isDictionarySourceFile(name: String): Boolean {
        if (name.endsWith(".mdx", ignoreCase = true) ||
            name.endsWith(".mdd", ignoreCase = true)) {
            return true
        }
        return isPublisherSidecar(name)
    }

    private fun documentLastModified(uri: Uri): Long? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
                null,
                null,
                null,
            )?.use { cursor ->
                val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getLong(index).takeIf { it > 0 }
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun documentName(uri: Uri): String {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && cursor.moveToFirst()) {
                cursor.getString(nameIndex)?.let { return it }
            }
        }
        return "dictionary.bin"
    }

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        openDescriptors.values.forEach { it.close() }
        openDescriptors.clear()
        super.onDestroy()
    }
}

private data class TreeDocument(
    val parentId: String,
    val name: String,
    val uri: Uri,
    val relativePath: List<String>,
    val size: Long?,
    val modifiedMillis: Long?,
) {
    val sourceVersion: String?
        get() = if (size != null && modifiedMillis != null) "$size:$modifiedMillis" else null
}
