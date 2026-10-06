package com.netvplayer.provider;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

/** Stable Java 21 SDK entrypoint. Existing CatVod classes may use the reflection adapter instead. */
public interface NetVplayerProvider {
    JsonElement invoke(String operation, JsonObject arguments) throws Exception;
}
