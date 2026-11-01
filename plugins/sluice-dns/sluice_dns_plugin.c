/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Copyright (C) 2026 Anton Zubkov
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.  See <http://www.fsf.org/copyleft/gpl.txt>.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 */

/**
 * sluice-dns: request DNS configuration attributes from the gateway and
 * publish them per IKE_SA for the Sluice helper, which applies them via
 * /etc/resolver. charon itself never touches system DNS.
 *
 * For every IKE_SA that received DNS attributes, the file
 *
 *   <dir>/<connection>.<unique id>
 *
 * is (re)written atomically on each handled attribute and removed when the
 * last one is released. Format, one key=value per line:
 *
 *   connection=<name>
 *   unique_id=<id>
 *   nameserver=<address>     (repeated)
 *   domain=<dns domain>      (repeated)
 *
 * The unique id keeps make-before-break reauthentication (two IKE_SAs of the
 * same connection alive at once) from clobbering each other's file. An IKE_SA
 * rekeying moves the attributes to the new IKE_SA, and the file with them.
 *
 * Split tunneling: the plugin also requests INTERNAL_IP4_SUBNET and
 * INTERNAL_IP6_SUBNET. Some gateways (FortiGate among them) answer the
 * client's 0.0.0.0/0 with 0.0.0.0/0 and announce the networks behind them
 * only as these attributes. If any were received, the remote traffic
 * selectors of each CHILD_SA of that IKE_SA are narrowed to them, so only
 * these networks are routed into the tunnel. Without them nothing changes.
 *
 * Settings: charon.plugins.sluice-dns.dir (default IPSEC_PIDDIR "/dns").
 * Built into charon by scripts/build-strongswan.sh.
 */

#include <daemon.h>
#include <attributes/attributes.h>
#include <plugins/plugin.h>
#include <plugins/plugin_loader.h>
#include <threading/mutex.h>
#include <collections/linked_list.h>

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef IPSEC_PIDDIR
#error IPSEC_PIDDIR must be defined (compile alongside charon.c)
#endif

#define DEFAULT_DIR IPSEC_PIDDIR "/dns"

/** longest connection name kept in a file name */
#define MAX_NAME 128

/** longest DNS domain accepted (RFC 1035) */
#define MAX_DOMAIN 253

/**
 * Attributes received for one IKE_SA
 */
typedef struct {
	/** IKE_SA unique id */
	u_int id;
	/** connection name, sanitized for use in a file name */
	char *name;
	/** DNS servers, host_t* */
	linked_list_t *servers;
	/** DNS domains, char* */
	linked_list_t *domains;
	/** networks behind the gateway, traffic_selector_t* */
	linked_list_t *subnets;
} entry_t;

static void entry_destroy(entry_t *this)
{
	this->servers->destroy_offset(this->servers, offsetof(host_t, destroy));
	this->domains->destroy_function(this->domains, free);
	this->subnets->destroy_offset(this->subnets,
								  offsetof(traffic_selector_t, destroy));
	free(this->name);
	free(this);
}

typedef struct private_handler_t private_handler_t;

/**
 * Attribute handler
 */
struct private_handler_t {

	/** implements attribute_handler_t */
	attribute_handler_t handler;

	/** narrows traffic selectors, follows IKE_SA rekeying */
	listener_t listener;

	/** directory for published files */
	char *dir;

	/** protects entries and the files */
	mutex_t *mutex;

	/** entry_t* */
	linked_list_t *entries;
};

/**
 * Copy a connection name, replacing anything but [A-Za-z0-9_-] so it can't
 * escape the directory or clash with the "<name>.<id>" separator.
 */
static char *sanitize_name(const char *name)
{
	char *out;
	int i;

	out = strndup(name ?: "", MAX_NAME);
	for (i = 0; out[i]; i++)
	{
		if (!isalnum((unsigned char)out[i]) && out[i] != '-' && out[i] != '_')
		{
			out[i] = '_';
		}
	}
	return out;
}

/**
 * Parse an INTERNAL_DNS_DOMAIN value, NULL if empty or not a plain domain
 */
static char *parse_domain(chunk_t data)
{
	int i;

	if (!data.len || data.len > MAX_DOMAIN)
	{
		return NULL;
	}
	for (i = 0; i < data.len; i++)
	{
		if (!isalnum(data.ptr[i]) && data.ptr[i] != '-' &&
			data.ptr[i] != '.' && data.ptr[i] != '_')
		{
			return NULL;
		}
	}
	return strndup((char*)data.ptr, data.len);
}

/**
 * Parse an INTERNAL_IP4_SUBNET (address and netmask) or INTERNAL_IP6_SUBNET
 * (address and prefix length) value, NULL if malformed
 */
static traffic_selector_t *parse_subnet(int family, chunk_t data)
{
	host_t *net;
	uint32_t mask;
	int bits;

	if (family == AF_INET)
	{
		if (data.len != 8)
		{
			return NULL;
		}
		mask = untoh32(data.ptr + 4);
		if (~mask & (~mask + 1))
		{	/* not a contiguous netmask */
			return NULL;
		}
		bits = __builtin_popcount(mask);
		data.len = 4;
	}
	else
	{
		if (data.len != 17 || data.ptr[16] > 128)
		{
			return NULL;
		}
		bits = data.ptr[16];
		data.len = 16;
	}
	net = host_create_from_chunk(family, data, 0);
	if (!net)
	{
		return NULL;
	}
	return traffic_selector_create_from_subnet(net, bits, 0, 0, 65535);
}

/**
 * Whether the entry has anything for the DNS file
 */
static bool has_dns(entry_t *entry)
{
	return entry->servers->get_count(entry->servers) ||
		   entry->domains->get_count(entry->domains);
}

/**
 * Create the directory if needed and make sure it is ours
 */
static bool ensure_dir(private_handler_t *this)
{
	struct stat st;

	if (mkdir(this->dir, 0755) != 0 && errno != EEXIST)
	{
		DBG1(DBG_CFG, "sluice-dns: creating '%s' failed: %s", this->dir,
			 strerror(errno));
		return FALSE;
	}
	if (lstat(this->dir, &st) != 0 || !S_ISDIR(st.st_mode) ||
		st.st_uid != geteuid() || (st.st_mode & (S_IWGRP | S_IWOTH)))
	{
		DBG1(DBG_CFG, "sluice-dns: '%s' is not a directory owned by us and "
			 "writable only by us", this->dir);
		return FALSE;
	}
	return TRUE;
}

static void entry_path(private_handler_t *this, entry_t *entry, char *path,
					   size_t len, bool tmp)
{
	snprintf(path, len, "%s/%s%s.%u%s", this->dir, tmp ? "." : "",
			 entry->name, entry->id, tmp ? ".tmp" : "");
}

/**
 * Atomically (re)write the file of an entry
 */
static void write_entry(private_handler_t *this, entry_t *entry)
{
	char path[PATH_MAX], tmp[PATH_MAX];
	enumerator_t *enumerator;
	host_t *host;
	char *domain;
	FILE *out;
	int fd;

	if (!ensure_dir(this))
	{
		return;
	}
	entry_path(this, entry, path, sizeof(path), FALSE);
	entry_path(this, entry, tmp, sizeof(tmp), TRUE);

	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
	out = fd == -1 ? NULL : fdopen(fd, "w");
	if (!out)
	{
		DBG1(DBG_CFG, "sluice-dns: writing '%s' failed: %s", tmp,
			 strerror(errno));
		if (fd != -1)
		{
			close(fd);
		}
		unlink(tmp);
		return;
	}
	fprintf(out, "connection=%s\nunique_id=%u\n", entry->name, entry->id);
	enumerator = entry->servers->create_enumerator(entry->servers);
	while (enumerator->enumerate(enumerator, &host))
	{
		fprintf(out, "nameserver=%H\n", host);
	}
	enumerator->destroy(enumerator);
	enumerator = entry->domains->create_enumerator(entry->domains);
	while (enumerator->enumerate(enumerator, &domain))
	{
		fprintf(out, "domain=%s\n", domain);
	}
	enumerator->destroy(enumerator);

	if (fflush(out) != 0 || fsync(fileno(out)) != 0)
	{
		DBG1(DBG_CFG, "sluice-dns: writing '%s' failed: %s", tmp,
			 strerror(errno));
		fclose(out);
		unlink(tmp);
		return;
	}
	fclose(out);
	if (rename(tmp, path) != 0)
	{
		DBG1(DBG_CFG, "sluice-dns: renaming '%s' failed: %s", tmp,
			 strerror(errno));
		unlink(tmp);
	}
}

/**
 * Write the file of an entry, or remove it if there is no DNS left
 */
static void publish_entry(private_handler_t *this, entry_t *entry)
{
	char path[PATH_MAX];

	if (has_dns(entry))
	{
		write_entry(this, entry);
	}
	else
	{
		entry_path(this, entry, path, sizeof(path), FALSE);
		unlink(path);
	}
}

/**
 * Find the entry of an IKE_SA, optionally creating it
 */
static entry_t *get_entry(private_handler_t *this, ike_sa_t *ike_sa,
						  bool create)
{
	enumerator_t *enumerator;
	entry_t *current, *found = NULL;
	u_int id;

	id = ike_sa->get_unique_id(ike_sa);
	enumerator = this->entries->create_enumerator(this->entries);
	while (enumerator->enumerate(enumerator, &current))
	{
		if (current->id == id)
		{
			found = current;
			break;
		}
	}
	enumerator->destroy(enumerator);

	if (!found && create)
	{
		INIT(found,
			.id = id,
			.name = sanitize_name(ike_sa->get_name(ike_sa)),
			.servers = linked_list_create(),
			.domains = linked_list_create(),
			.subnets = linked_list_create(),
		);
		this->entries->insert_last(this->entries, found);
	}
	return found;
}

METHOD(attribute_handler_t, handle, bool,
	private_handler_t *this, ike_sa_t *ike_sa,
	configuration_attribute_type_t type, chunk_t data)
{
	entry_t *entry;
	host_t *host = NULL;
	char *domain = NULL;
	traffic_selector_t *subnet = NULL;

	switch (type)
	{
		case INTERNAL_IP4_DNS:
			host = host_create_from_chunk(AF_INET, data, 0);
			break;
		case INTERNAL_IP6_DNS:
			host = host_create_from_chunk(AF_INET6, data, 0);
			break;
		case INTERNAL_DNS_DOMAIN:
			domain = parse_domain(data);
			break;
		case INTERNAL_IP4_SUBNET:
			subnet = parse_subnet(AF_INET, data);
			break;
		case INTERNAL_IP6_SUBNET:
			subnet = parse_subnet(AF_INET6, data);
			break;
		default:
			return FALSE;
	}
	if (host && host->is_anyaddr(host))
	{
		host->destroy(host);
		host = NULL;
	}
	if (!host && !domain && !subnet)
	{
		DBG1(DBG_CFG, "sluice-dns: ignoring invalid %N attribute",
			 configuration_attribute_type_names, type);
		return FALSE;
	}

	this->mutex->lock(this->mutex);
	entry = get_entry(this, ike_sa, TRUE);
	if (host)
	{
		DBG1(DBG_CFG, "sluice-dns: DNS server %H for '%s'", host, entry->name);
		entry->servers->insert_last(entry->servers, host);
		write_entry(this, entry);
	}
	else if (domain)
	{
		DBG1(DBG_CFG, "sluice-dns: DNS domain %s for '%s'", domain,
			 entry->name);
		entry->domains->insert_last(entry->domains, domain);
		write_entry(this, entry);
	}
	else
	{
		DBG1(DBG_CFG, "sluice-dns: network %R for '%s'", subnet, entry->name);
		entry->subnets->insert_last(entry->subnets, subnet);
	}
	this->mutex->unlock(this->mutex);
	return TRUE;
}

METHOD(attribute_handler_t, release, void,
	private_handler_t *this, ike_sa_t *ike_sa,
	configuration_attribute_type_t type, chunk_t data)
{
	enumerator_t *enumerator;
	entry_t *entry;
	host_t *host = NULL, *current;
	char *domain = NULL, *cur_domain;
	traffic_selector_t *subnet = NULL, *cur_subnet;

	switch (type)
	{
		case INTERNAL_IP4_DNS:
			host = host_create_from_chunk(AF_INET, data, 0);
			break;
		case INTERNAL_IP6_DNS:
			host = host_create_from_chunk(AF_INET6, data, 0);
			break;
		case INTERNAL_DNS_DOMAIN:
			domain = parse_domain(data);
			break;
		case INTERNAL_IP4_SUBNET:
			subnet = parse_subnet(AF_INET, data);
			break;
		case INTERNAL_IP6_SUBNET:
			subnet = parse_subnet(AF_INET6, data);
			break;
		default:
			return;
	}

	this->mutex->lock(this->mutex);
	entry = get_entry(this, ike_sa, FALSE);
	if (entry && host)
	{
		enumerator = entry->servers->create_enumerator(entry->servers);
		while (enumerator->enumerate(enumerator, &current))
		{
			if (current->ip_equals(current, host))
			{
				entry->servers->remove_at(entry->servers, enumerator);
				current->destroy(current);
				break;
			}
		}
		enumerator->destroy(enumerator);
	}
	if (entry && domain)
	{
		enumerator = entry->domains->create_enumerator(entry->domains);
		while (enumerator->enumerate(enumerator, &cur_domain))
		{
			if (streq(cur_domain, domain))
			{
				entry->domains->remove_at(entry->domains, enumerator);
				free(cur_domain);
				break;
			}
		}
		enumerator->destroy(enumerator);
	}
	if (entry && subnet)
	{
		enumerator = entry->subnets->create_enumerator(entry->subnets);
		while (enumerator->enumerate(enumerator, &cur_subnet))
		{
			if (cur_subnet->equals(cur_subnet, subnet))
			{
				entry->subnets->remove_at(entry->subnets, enumerator);
				cur_subnet->destroy(cur_subnet);
				break;
			}
		}
		enumerator->destroy(enumerator);
	}
	if (entry && (host || domain))
	{
		publish_entry(this, entry);
		if (!has_dns(entry))
		{
			DBG1(DBG_CFG, "sluice-dns: removed DNS for '%s'", entry->name);
		}
	}
	if (entry && !has_dns(entry) && !entry->subnets->get_count(entry->subnets))
	{
		this->entries->remove(this->entries, entry, NULL);
		entry_destroy(entry);
	}
	this->mutex->unlock(this->mutex);

	DESTROY_IF(host);
	free(domain);
	DESTROY_IF(subnet);
}

/**
 * Enumerator over the attribute types we request
 */
typedef struct {
	enumerator_t public;
	configuration_attribute_type_t types[5];
	int count;
	int pos;
} attribute_enumerator_t;

METHOD(enumerator_t, attribute_enumerate, bool,
	attribute_enumerator_t *this, va_list args)
{
	configuration_attribute_type_t *type;
	chunk_t *data;

	VA_ARGS_VGET(args, type, data);
	if (this->pos >= this->count)
	{
		return FALSE;
	}
	*type = this->types[this->pos++];
	*data = chunk_empty;
	return TRUE;
}

static bool has_family(linked_list_t *vips, int family)
{
	enumerator_t *enumerator;
	host_t *host;
	bool found = FALSE;

	enumerator = vips->create_enumerator(vips);
	while (enumerator->enumerate(enumerator, &host))
	{
		if (host->get_family(host) == family)
		{
			found = TRUE;
			break;
		}
	}
	enumerator->destroy(enumerator);
	return found;
}

METHOD(attribute_handler_t, create_attribute_enumerator, enumerator_t*,
	private_handler_t *this, ike_sa_t *ike_sa, linked_list_t *vips)
{
	attribute_enumerator_t *enumerator;

	INIT(enumerator,
		.public = {
			.enumerate = enumerator_enumerate_default,
			.venumerate = _attribute_enumerate,
			.destroy = (void*)free,
		},
	);
	if (has_family(vips, AF_INET))
	{
		enumerator->types[enumerator->count++] = INTERNAL_IP4_DNS;
		enumerator->types[enumerator->count++] = INTERNAL_IP4_SUBNET;
	}
	if (has_family(vips, AF_INET6))
	{
		enumerator->types[enumerator->count++] = INTERNAL_IP6_DNS;
		enumerator->types[enumerator->count++] = INTERNAL_IP6_SUBNET;
	}
	if (enumerator->count)
	{
		enumerator->types[enumerator->count++] = INTERNAL_DNS_DOMAIN;
	}
	return &enumerator->public;
}

/**
 * Replace the remote traffic selectors with their intersections with the
 * received networks. Left as is if none of the networks falls within them.
 */
static void narrow_remote(entry_t *entry, linked_list_t *remote)
{
	enumerator_t *enumerator, *subnets;
	traffic_selector_t *ts, *subnet, *subset;
	linked_list_t *narrowed;

	narrowed = linked_list_create();
	enumerator = remote->create_enumerator(remote);
	while (enumerator->enumerate(enumerator, &ts))
	{
		subnets = entry->subnets->create_enumerator(entry->subnets);
		while (subnets->enumerate(subnets, &subnet))
		{
			subset = subnet->get_subset(subnet, ts);
			if (subset)
			{
				narrowed->insert_last(narrowed, subset);
			}
		}
		subnets->destroy(subnets);
	}
	enumerator->destroy(enumerator);

	if (!narrowed->get_count(narrowed))
	{
		DBG1(DBG_CFG, "sluice-dns: no network of '%s' within %#R, not narrowed",
			 entry->name, remote);
		narrowed->destroy(narrowed);
		return;
	}
	while (remote->remove_first(remote, (void**)&ts) == SUCCESS)
	{
		ts->destroy(ts);
	}
	while (narrowed->remove_first(narrowed, (void**)&ts) == SUCCESS)
	{
		remote->insert_last(remote, ts);
	}
	narrowed->destroy(narrowed);
	DBG1(DBG_CFG, "sluice-dns: narrowed CHILD_SA of '%s' to %#R", entry->name,
		 remote);
}

/**
 * The handler of the embedded listener the bus calls us with
 */
static private_handler_t *from_listener(listener_t *listener)
{
	return (private_handler_t*)((char*)listener -
								offsetof(private_handler_t, listener));
}

METHOD(listener_t, narrow, bool,
	listener_t *listener, ike_sa_t *ike_sa, child_sa_t *child_sa,
	narrow_hook_t type, linked_list_t *local, linked_list_t *remote)
{
	private_handler_t *this = from_listener(listener);
	entry_t *entry;

	if (ike_sa->get_version(ike_sa) != IKEV2)
	{
		return TRUE;
	}
	switch (type)
	{
		/* after the gateway answered our proposal, or when it rekeys a
		 * CHILD_SA, which may restore what it answered at first */
		case NARROW_INITIATOR_POST_NOAUTH:
		case NARROW_INITIATOR_POST_AUTH:
		case NARROW_RESPONDER:
			break;
		default:
			return TRUE;
	}
	this->mutex->lock(this->mutex);
	entry = get_entry(this, ike_sa, FALSE);
	if (entry && entry->subnets->get_count(entry->subnets))
	{
		narrow_remote(entry, remote);
	}
	this->mutex->unlock(this->mutex);
	return TRUE;
}

METHOD(listener_t, ike_rekey, bool,
	listener_t *listener, ike_sa_t *old, ike_sa_t *new)
{
	private_handler_t *this = from_listener(listener);
	char path[PATH_MAX];
	entry_t *entry;

	/* the attributes move to the new IKE_SA, which has another unique id */
	this->mutex->lock(this->mutex);
	entry = get_entry(this, old, FALSE);
	if (entry)
	{
		entry_path(this, entry, path, sizeof(path), FALSE);
		unlink(path);
		entry->id = new->get_unique_id(new);
		publish_entry(this, entry);
	}
	this->mutex->unlock(this->mutex);
	return TRUE;
}

/**
 * Remove files left behind by a previous charon (none of its SAs survive)
 */
static void clean_dir(private_handler_t *this)
{
	char path[PATH_MAX];
	struct dirent *ent;
	struct stat st;
	DIR *dir;

	if (!ensure_dir(this) || !(dir = opendir(this->dir)))
	{
		return;
	}
	while ((ent = readdir(dir)))
	{
		snprintf(path, sizeof(path), "%s/%s", this->dir, ent->d_name);
		if (lstat(path, &st) == 0 && S_ISREG(st.st_mode))
		{
			unlink(path);
		}
	}
	closedir(dir);
}

static void handler_destroy(private_handler_t *this)
{
	char path[PATH_MAX];
	entry_t *entry;

	while (this->entries->remove_first(this->entries,
									   (void**)&entry) == SUCCESS)
	{
		entry_path(this, entry, path, sizeof(path), FALSE);
		unlink(path);
		entry_destroy(entry);
	}
	this->entries->destroy(this->entries);
	this->mutex->destroy(this->mutex);
	free(this);
}

static private_handler_t *handler_create()
{
	private_handler_t *this;

	INIT(this,
		.handler = {
			.handle = _handle,
			.release = _release,
			.create_attribute_enumerator = _create_attribute_enumerator,
		},
		.listener = {
			.narrow = _narrow,
			.ike_rekey = _ike_rekey,
		},
		.dir = lib->settings->get_str(lib->settings,
							"%s.plugins.sluice-dns.dir", DEFAULT_DIR, lib->ns),
		.mutex = mutex_create(MUTEX_TYPE_DEFAULT),
		.entries = linked_list_create(),
	);
	return this;
}

typedef struct {
	/** implements plugin_t */
	plugin_t public;
	/** the registered handler */
	private_handler_t *handler;
} private_plugin_t;

METHOD(plugin_t, get_name, char*,
	private_plugin_t *this)
{
	return "sluice-dns";
}

static bool plugin_cb(private_plugin_t *this, plugin_feature_t *feature,
					  bool reg, void *cb_data)
{
	if (reg)
	{
		clean_dir(this->handler);
		charon->attributes->add_handler(charon->attributes,
										&this->handler->handler);
		charon->bus->add_listener(charon->bus, &this->handler->listener);
	}
	else
	{
		charon->bus->remove_listener(charon->bus, &this->handler->listener);
		charon->attributes->remove_handler(charon->attributes,
										   &this->handler->handler);
	}
	return TRUE;
}

METHOD(plugin_t, get_features, int,
	private_plugin_t *this, plugin_feature_t *features[])
{
	static plugin_feature_t f[] = {
		PLUGIN_CALLBACK((plugin_feature_callback_t)plugin_cb, NULL),
			PLUGIN_PROVIDE(CUSTOM, "sluice-dns"),
	};
	*features = f;
	return countof(f);
}

METHOD(plugin_t, destroy, void,
	private_plugin_t *this)
{
	handler_destroy(this->handler);
	free(this);
}

PLUGIN_DEFINE(sluice_dns)
{
	private_plugin_t *this;

	INIT(this,
		.public = {
			.get_name = _get_name,
			.get_features = _get_features,
			.destroy = _destroy,
		},
		.handler = handler_create(),
	);
	return &this->public;
}

#ifdef STATIC_PLUGIN_CONSTRUCTORS
static void register_plugin() __attribute__ ((constructor));
static void register_plugin()
{
	plugin_constructor_register("sluice-dns", sluice_dns_plugin_create);
}

static void unregister_plugin() __attribute__ ((destructor));
static void unregister_plugin()
{
	plugin_constructor_register("sluice-dns", NULL);
}
#endif
