package com.fortune.vibramusic.data.webdav

/**
 * In-memory credentials for [com.fortune.vibramusic.data.Http]'s interceptor.
 *
 * Held outside SharedPreferences so the network layer never touches prefs:
 * [com.fortune.vibramusic.data.settings.AppSettings] publishes here on init and
 * on every WebDAV edit.
 */
object WebDavAuth {
    @Volatile var host: String? = null
    @Volatile var authHeader: String? = null

    /** [host] and [header] as WebDavConfig derives them from the saved server. */
    fun update(host: String?, header: String?) {
        this.host = host
        authHeader = header
    }

    fun update(url: String, username: String, password: String) {
        val parsedHost = runCatching {
            val trimmed = url.trim()
            val uri = if (trimmed.contains("://")) java.net.URI(trimmed) else java.net.URI("http://$trimmed")
            uri.host
        }.getOrNull()
        val header = if (username.isNotBlank() || password.isNotBlank()) {
            val userPass = "$username:$password"
            val encoded = java.util.Base64.getEncoder().encodeToString(userPass.toByteArray(Charsets.UTF_8))
            "Basic $encoded"
        } else null
        update(parsedHost, header)
    }

    fun shouldAuthorize(requestHost: String): Boolean {
        val expected = host ?: return false
        val header = authHeader ?: return false
        if (header.isBlank()) return false
        return requestHost.equals(expected, ignoreCase = true)
    }
}
