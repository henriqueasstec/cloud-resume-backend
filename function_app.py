import azure.functions as func
import logging
import os
import json
from azure.data.tables import TableServiceClient

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@app.route(route="counter", methods=["GET"])
def counter(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Recebida requisição para o contador de visitas.')

    try:
        connection_string = os.environ["COSMOS_CONNECTION_STRING"]
        table_name = "Counter"

        table_service = TableServiceClient.from_connection_string(connection_string)
        table_client = table_service.get_table_client(table_name)

        partition_key = "visits"
        row_key = "count"

        try:
            entity = table_client.get_entity(partition_key=partition_key, row_key=row_key)
            entity["Count"] = entity["Count"] + 1
        except Exception:
            entity = {
                "PartitionKey": partition_key,
                "RowKey": row_key,
                "Count": 1
            }

        table_client.upsert_entity(entity)

        response_body = json.dumps({"count": entity["Count"]})

        return func.HttpResponse(
            body=response_body,
            mimetype="application/json",
            status_code=200
        )

    except Exception as e:
        logging.error(f"Erro ao processar o contador: {str(e)}")
        return func.HttpResponse(
            body=json.dumps({"error": "Erro interno ao processar a requisição."}),
            mimetype="application/json",
            status_code=500
        )