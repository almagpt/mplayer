package com.streamvault.feature.provider.setup

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

internal object PartnerAccessClient {
    private const val ENDPOINT = "https://mplayer.up.railway.app/v1/partner-access/"

    fun resolveDns(code: String): String {
        val normalized = code.trim()
        if (normalized.isEmpty()) error("Informe o código do parceiro")
        val connection = (URL(ENDPOINT + URLEncoder.encode(normalized, Charsets.UTF_8.name())).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 12_000
            readTimeout = 12_000
        }
        try {
            if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                error("Código de parceiro não encontrado")
            }
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val dns = JSONObject(body).optString("dns_url")
            if (!dns.startsWith("http://") && !dns.startsWith("https://")) {
                error("A DNS deste parceiro ainda não foi configurada")
            }
            return dns
        } finally {
            connection.disconnect()
        }
    }
}
