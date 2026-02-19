package com.clipshare.pairing

data class PairingPayload(
    val token: String,
    val serviceUUID: String,
    val macPublicKey: String
)
