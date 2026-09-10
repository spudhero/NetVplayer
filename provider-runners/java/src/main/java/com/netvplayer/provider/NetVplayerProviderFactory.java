package com.netvplayer.provider;

import com.google.gson.JsonObject;

public interface NetVplayerProviderFactory {
    Object providerFor(JsonObject site, Object extension) throws Exception;
}
