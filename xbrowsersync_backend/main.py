'''API handler for xBrowserSync'''
import logging
import json
import uuid
import os
import re
import sys
import time
import site
import traceback
import subprocess
from datetime import datetime
from importlib import reload

import azure.functions as func

subprocess.check_call([sys.executable, "-m", "pip", "install", "azure-cosmos"])
subprocess.check_call([sys.executable, "-m", "pip", "install", "azure-identity"])
subprocess.check_call([sys.executable, "-m", "pip", "install", "azure-mgmt-cosmosdb"])
reload(site)

# pylint: disable=wrong-import-position
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from azure.mgmt.cosmosdb import CosmosDBManagementClient

subscription_id = os.environ['SUBSCRIPTION_ID']
resource_group = os.environ['RESOURCE_GROUP']
account_name = os.environ['DATABASE_ACCOUNT_NAME']
db_url = os.environ['DATABASE_URL']
db_name = os.environ['DATABASE_NAME']
db_container = os.environ['DATABASE_CONTAINER']


def main(req: func.HttpRequest) -> func.HttpResponse:
    '''Azure Function main handler function'''
    logging.info('URL of the http request is %s', req.url)

    uri_recieved = req.params.get('uri')
    logging.info('Recieved HTTP method %s', req.method)

    try:
        credential = DefaultAzureCredential()
        dbmgmt = CosmosDBManagementClient(credential, subscription_id)
        keys = dbmgmt.database_accounts.list_keys(resource_group, account_name)

        logging.info('Creating Cosmos DB client')
        cosmos_client = CosmosClient(url=db_url, credential=keys.primary_master_key)
        logging.info('Getting Database client')
        db_client = cosmos_client.get_database_client(db_name)
        logging.info('Getting Container client')
        cont_client = db_client.get_container_client(db_container)

        if req.method.lower() == 'post' and uri_recieved == '/bookmarks':
            logging.info('Creating a new bookmark')
            vers = req.get_json().get('version')
            uniq_id = uuid.uuid4().hex[:32]
            curr_time = datetime.utcnow().isoformat()[:-3]+'Z'
            func_res = create_bookmark(cont_client, vers, uniq_id, curr_time)
        elif req.method.lower() == 'put' and \
            re.fullmatch('^/bookmarks/[0-9a-f]{32}$', uri_recieved):
            bookmarks = req.get_json().get('bookmarks')
            last_updated = req.get_json().get('lastUpdated')
            curr_id = uri_recieved.split('/')[2]
            if len(bookmarks) > 204800:
                func_res = func.HttpResponse(
                    json.dumps({'SyncDataLimitExceededException': 'Sync data limit exceeded'}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code= 413
                )
            else:
                logging.info('Updating an existing bookmark with id %s', curr_id)
                func_res = update_bookmark(cont_client, curr_id, bookmarks, last_updated)
        elif req.method.lower() == 'get' and \
            re.fullmatch('^/bookmarks/[0-9a-f]{32}/lastUpdated$', uri_recieved):
            curr_id = uri_recieved.split('/')[2]
            logging.info('Obtained Sync Id - %s', curr_id)
            func_res = get_last_updated(cont_client, curr_id)
        elif req.method.lower() == 'get' and \
            re.fullmatch('^/bookmarks/[0-9a-f]{32}/version$', uri_recieved):
            curr_id = uri_recieved.split('/')[2]
            logging.info('Obtained Sync Id - %s', curr_id)
            func_res = get_version(cont_client, curr_id)
        else:
            logging.info('Doesnt match any supported operations')
            logging.info('Recieved HTTP method %s and URI %s', req.method.lower(), uri_recieved)
            time.sleep(3)
            func_res = func.HttpResponse(
                json.dumps({
                    'UnspecifiedException': 'Unsupported operation. Check the logs for details'
                }),
                status_code=500
            )
        return func_res
    # pylint: disable=bare-except
    except:
        logging.info(traceback.print_exc())
        return func.HttpResponse(
            json.dumps({
                'UnspecifiedException':'Failed with an exception. Check the logs for details'}),
            status_code=500
        )


def create_bookmark(cont_client, vers, uniq_id, curr_time):
    '''Function to create a new bookmarks sync id'''
    content = {
        'id': uniq_id,
        'lastUpdated': curr_time,
        'version': vers
    }
    logging.info('Creating a new Id in CosmosDB')
    try:
        create_res = cont_client.upsert_item(content)
        logging.info(json.dumps(create_res))
        if create_res['id'] == uniq_id:
            return func.HttpResponse(
                json.dumps(content),
                mimetype='application/json',
                charset='utf-8',
                status_code=200
            )

        logging.info(json.dumps(create_res))
        return func.HttpResponse(
            json.dumps({
                'UnspecifiedException':
                'Failed to insert record in CosmosDB. Check the logs for details'
            }),
            status_code=500
        )
    # pylint: disable=bare-except
    except:
        logging.error(traceback.print_exc())
        return func.HttpResponse(
                json.dumps({
                    'UnspecifiedException': 'Failed with an exception. Check the logs for details'
                }),
                status_code=500
            )


def update_bookmark(cont_client, curr_id, bookmarks, last_updated):
    '''Function update bookmarks of existing sync Id'''
    logging.info('Updating an existing id in CosmosDB')
    try:
        existing_items = cont_client.query_items(query=f'SELECT * FROM x where x.id = "{curr_id}"')
        curr_item = None
        for item in existing_items:
            if item.get('id') == curr_id:
                logging.info('Inside the item check condition - %s', item.get("id"))
                curr_item = item

        if not curr_item:
            logging.info('Provided sync id %s is invalid', curr_id)
            return func.HttpResponse(
                json.dumps({'InvalidSyncIdException': 'Invalid sync ID'}),
                status_code=401
            )

        if curr_item.get('lastUpdated') == last_updated:
            curr_time = datetime.utcnow().isoformat()[:-3]+'Z'
            content = {
                'id': curr_id,
                'bookmarks': bookmarks,
                'lastUpdated': curr_time,
                'version': curr_item['version']
            }
            create_res = cont_client.upsert_item(content)
            logging.info(json.dumps(create_res))
            if create_res['id'] == curr_id:
                return func.HttpResponse(
                    json.dumps({'lastUpdated': curr_time}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code=200
                    )

            logging.info(json.dumps(create_res))
            return func.HttpResponse(
                json.dumps({
                    'UnspecifiedException':
                    'Failed to update record in CosmosDB. Check the logs for details'
                }),
                status_code=500
            )

        logging.info(
            'Last updated time provided by API request is %s whereas in the database it is %s',
            last_updated,
            curr_item.get("lastUpdated"))
        return func.HttpResponse(
            json.dumps({'SyncConflictException': 'A sync conflict was detected'}),
            status_code=409
        )
    # pylint: disable=bare-except
    except:
        logging.error(traceback.print_exc())
        return func.HttpResponse(
                json.dumps({
                    'UnspecifiedException': 'Failed with an exception. Check the logs for details'
                }),
                status_code=500
            )


def get_last_updated(cont_client, curr_id):
    '''Function to obtain the last updated timestamp of specific sync Id'''
    logging.info('Getting the last updated time for Id - %s', curr_id)
    try:
        existing_items = cont_client.query_items(query=f'SELECT * FROM x where x.id = "{curr_id}"')
        curr_item = None
        for item in existing_items:
            if item.get('id') == curr_id:
                logging.info('Inside the item check condition - %s', item.get("id"))
                curr_item = item

        if not curr_item:
            logging.info('Provided sync id %s is invalid', curr_id)
            return func.HttpResponse(
                    json.dumps({'InvalidSyncIdException': 'Invalid sync ID'}),
                    status_code=401
                )

        return func.HttpResponse(
                    json.dumps({'lastUpdated': curr_item['lastUpdated']}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code=200
                )
    # pylint: disable=bare-except
    except:
        logging.error(traceback.print_exc())
        return func.HttpResponse(
                json.dumps({
                    'UnspecifiedException': 'Failed with an exception. Check the logs for details'
                }),
                status_code=500
            )


def get_version(cont_client, curr_id):
    '''Function to obtain the version of the specific sync Id'''
    logging.info('Getting the version for Id - %s', curr_id)
    try:
        existing_items = cont_client.query_items(query=f'SELECT * FROM x where x.id = "{curr_id}"')
        curr_item = None
        for item in existing_items:
            if item.get('id') == curr_id:
                logging.info('Inside the item check condition - %s', item.get("id"))
                curr_item = item

        if not curr_item:
            logging.info('Provided sync id %s is invalid', curr_id)
            return func.HttpResponse(
                    json.dumps({'InvalidSyncIdException': 'Invalid sync ID'}),
                    status_code=401
                )

        return func.HttpResponse(
                    json.dumps({'version': curr_item.get('version')}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code=200
                )
    # pylint: disable=bare-except
    except:
        logging.error(traceback.print_exc())
        return func.HttpResponse(
                json.dumps({
                    'UnspecifiedException': 'Failed with an exception. Check the logs for details'
                }),
                status_code=500
            )
