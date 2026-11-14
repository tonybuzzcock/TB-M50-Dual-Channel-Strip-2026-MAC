// M50Clap.h
// The three entry functions clap-wrapper links into every format.

#pragma once

bool tbm50_entry_init (const char* pluginPath);
void tbm50_entry_deinit();
const void* tbm50_entry_get_factory (const char* factoryId);
