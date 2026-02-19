package com.clipshare.models

data class ClipboardContent(
    val hash: String,
    val size: Int,
    val type: String,
    val payload: ByteArray
)
