package com.patrimonio.patrimonio

import android.os.Build
import androidx.core.content.ContextCompat
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native passkey (WebAuthn) bridge for the Dart PasskeyService io impl.
 *
 * Deliberately a raw JSON pass-through: the backend (webauthn-rs) speaks
 * standard WebAuthn JSON, and androidx.credentials' requestJson /
 * *ResponseJson are exactly that format — so the channel carries opaque
 * JSON strings both ways and NOTHING is lost in typed re-modelling.
 * (A third-party plugin was rejected for precisely that reason: its typed
 * login options dropped `allowCredentials`, which a non-discoverable
 * security-key credential needs to assert at all.)
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "patrimonio/passkeys"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Passkeys via Credential Manager need GMS + API 28
                    // (Android 9); on older devices the Dart side keeps the
                    // passkey UI hidden.
                    "isAvailable" -> result.success(Build.VERSION.SDK_INT >= 28)
                    "create" -> {
                        val json = call.argument<String>("requestJson")
                        if (json == null) {
                            result.error("bad_args", "requestJson is required", null)
                        } else {
                            createPasskey(json, result)
                        }
                    }
                    "getCredential" -> {
                        val json = call.argument<String>("requestJson")
                        if (json == null) {
                            result.error("bad_args", "requestJson is required", null)
                        } else {
                            getPasskey(json, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Registration ceremony: server's PublicKeyCredentialCreationOptions
     * JSON in, authenticator's registration response JSON out.
     */
    private fun createPasskey(requestJson: String, channelResult: MethodChannel.Result) {
        val request = CreatePublicKeyCredentialRequest(requestJson = requestJson)
        CredentialManager.create(this).createCredentialAsync(
            this,
            request,
            null,
            ContextCompat.getMainExecutor(this),
            object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(result: CreateCredentialResponse) {
                    val response = result as? CreatePublicKeyCredentialResponse
                    if (response == null) {
                        channelResult.error("bad_response", "Unexpected credential type", null)
                    } else {
                        channelResult.success(response.registrationResponseJson)
                    }
                }

                override fun onError(e: CreateCredentialException) {
                    // e.type carries the androidx failure constant, and for DOM
                    // exceptions the embedded WebAuthn error name (e.g.
                    // ...TYPE_CREATE_PUBLIC_KEY_CREDENTIAL_DOM_EXCEPTION/
                    // androidx.credentials.TYPE_INVALID_STATE_ERROR). The Dart
                    // side string-matches on it the same way the web impl
                    // matches DOMException names.
                    channelResult.error(e.type, e.message, null)
                }
            },
        )
    }

    /**
     * Authentication / step-up assertion ceremony: server's
     * PublicKeyCredentialRequestOptions JSON in, assertion JSON out.
     */
    private fun getPasskey(requestJson: String, channelResult: MethodChannel.Result) {
        val request = GetCredentialRequest(
            listOf(GetPublicKeyCredentialOption(requestJson = requestJson)),
        )
        CredentialManager.create(this).getCredentialAsync(
            this,
            request,
            null,
            ContextCompat.getMainExecutor(this),
            object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(result: GetCredentialResponse) {
                    val credential = result.credential as? PublicKeyCredential
                    if (credential == null) {
                        channelResult.error("bad_response", "Unexpected credential type", null)
                    } else {
                        channelResult.success(credential.authenticationResponseJson)
                    }
                }

                override fun onError(e: GetCredentialException) {
                    channelResult.error(e.type, e.message, null)
                }
            },
        )
    }
}
