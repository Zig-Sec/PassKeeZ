#include <stdio.h>
#include <signal.h>
#include <string.h> // memcpy(),
#include "keylib/keylib.h"
#include "keylib/uhid.h" // uhid_open(), uhid_close()
#include "tresor/tresor.h"

#define PATH "~/.keypass/db.trs"
#define PW "super-secret"

int up(const char* info, const char* user, const char* rp) {
    printf("up\n");
    return UpResult_Accepted;
}

int uv() {
    printf("uv\n");
    return UpResult_Accepted;
}

int select_cred(const char* rpId, char** users) {
    printf("select\n");
    return -1;
}

int auth_read(const char* id, const char* rp, char*** out) {
    int ret = Error_DoesNotExist;
    Tresor db = Tresor_open(PATH, PW);
    if (db == NULL) {
        printf("error: unable to load db at %s\n", PATH);
        fflush(stdout);
        return Error_DoesNotExist;
    }

    if (id) {
        Entry e = Tresor_entry_get(db, id);
        if (e == NULL) {
            printf("warning: no entry with id %s found\n", id);
            fflush(stdout);
            Tresor_deinit(db);
            return Error_DoesNotExist;
        }

        char* data = Tresor_entry_field_get(e, "Data");
        if (data == NULL) {
            printf("error: no Data field for entry with id %s\n", id);
            fflush(stdout);
            Tresor_deinit(db);
            return Error_DoesNotExist;
        }
        
        char** x = malloc(sizeof(char*) * 2);
        x[0] = data;
        x[1] = NULL;
        *out = x;

        ret = Error_SUCCESS;
    } else if (rp) {
        char* k = "Url:";
        char* filter = malloc(strlen(k) + strlen(rp) + 1);
        memcpy(&filter[0], k, 4);
        memcpy(&filter[4], rp, strlen(rp));
        filter[strlen(k) + strlen(rp)] = 0;
        
        char** x = NULL;
        size_t l = 0;
        void** entries = Tresor_entry_get_many(db, filter);
        if (!entries) {
            printf("error: no entries found for relying party %s\n", rp);
            fflush(stdout);
            free(filter);
            Tresor_deinit(db);
            return Error_DoesNotExist;
        }
        while (*entries) {
            char* data = Tresor_entry_field_get(*entries, "Data");
            if (!data) {
                continue;
            }

            l++;
            if (l == 1) {
                x = malloc(sizeof(char*));
            } else {
                x = realloc(x, sizeof(char*) * l);
            }
            
            x[l-1] = data; 

            entries++;
        }

        if (x != NULL) {
            x = realloc(x, sizeof(char*) * (l + 1));
            x[l] = NULL;
            *out = x;
            ret = Error_SUCCESS;
        }

        free(filter);
    }

    Tresor_deinit(db);
    return ret;
}

int auth_write(const char* id, const char* rp, const char* data) {
    fflush(stdout);

    int ret = Error_SUCCESS;
    Tresor db = Tresor_open(PATH, PW);
    if (!db) {
        printf("error: unable to load db at %s\n", PATH);
        fflush(stdout);
        return Error_DoesNotExist;
    }

    Entry e = Tresor_entry_get(db, id);
    if (!e) {
        if (Tresor_entry_create(db, id) != ERR_SUCCESS) {
            printf("error: unable to create entry for id %s\n", id);
            fflush(stdout);
            Tresor_deinit(db);
            return Error_Other;
        }
        e = Tresor_entry_get(db, id);
        if (Tresor_entry_field_add(e, "Url", rp) != ERR_SUCCESS) {
            printf("error: unable to set Url (%s) for entry with id %s\n", rp, id);
            fflush(stdout);
            Tresor_deinit(db);
            return Error_Other;
        }
        if (Tresor_entry_field_add(e, "Data", data) != ERR_SUCCESS) {
            printf("error: unable to persist Data for entry with id %s\n", id);
            fflush(stdout);
            Tresor_deinit(db);
            return Error_Other;
        }
    } else {
        if (Tresor_entry_field_update(e, "Data", data) != ERR_SUCCESS) {
            printf("error: unable to update Data for entry with id %s\n", id);
            fflush(stdout);
            Tresor_deinit(db);
            return Error_Other;
        }
    }

    Tresor_seal(db, PATH, PW);
    Tresor_deinit(db);
    return ret;
}

int auth_delete(const char* id) {
    printf("delete\n");
    return -1;
}

static int CLOSE = 0;

void sigint_handler(sig_t s) {
    CLOSE = 1;
}

int main() {
    Callbacks c = {
        up, uv, select_cred, auth_read, auth_write, auth_delete
    }; 

    // -------------------------------------------------------
    // Init Start
    // -------------------------------------------------------

    Tresor db = Tresor_open(PATH, PW);
    if (!db) {
        printf("info: no database found. Creating new one...");
        db = Tresor_new("keypass");
        if (!db) {
            printf("error: unable to create database");
            exit(1);
        }
        if (Tresor_seal(db, PATH, PW) != ERR_SUCCESS) {
            printf("error: unable to persist database");
            exit(1);
        }
        printf("info: database created in `%s`", PATH);
    }
    Tresor_deinit(db);
    
    // Instantiate the authenticator
    void* auth = auth_init(c);

    // Instantiate a ctaphid handler
    void* ctaphid = ctaphid_init();

    // Now lets create a (virtual) USB-HID device
    int fd = uhid_open();

    // -------------------------------------------------------
    // Init End
    // -------------------------------------------------------
    
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // Main Start
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++
    
    while (!CLOSE) {
        char buffer[64];
        
        int packet_length = uhid_read_packet(fd, &buffer[0]);
        if (packet_length) {
            // The handler will either return NULL or a pointer to
            // a ctaphid packet iterator.
            void* iter = ctaphid_handle(ctaphid, &buffer[0], packet_length, auth);

            // Every call to next will return a 64 byte packet ready
            // to be sent to the host. 
            if (iter) {
                char out[64];

                while(ctaphid_iterator_next(iter, &out[0])) {
                    uhid_write_packet(fd, &out[0], 64);
                }

                // Don't forget to free the iterator
                ctaphid_iterator_deinit(iter);
            }
        }
    }
    
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // Main End
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++

    // -------------------------------------------------------
    // Deinit Start
    // -------------------------------------------------------

    // We have to clean up the (virtual) USB-HID device we created
    uhid_close(fd);
    
    // Free the ctaphid instance
    ctaphid_deinit(ctaphid);

    // Free the authenticator instance
    auth_deinit(auth);

    // -------------------------------------------------------
    // Deinit End
    // -------------------------------------------------------

    return 0;
}
