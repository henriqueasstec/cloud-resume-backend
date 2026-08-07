import json
import os
import sys
from unittest.mock import MagicMock, patch

import azure.functions as func

# Garante que o Python encontra o function_app.py na pasta pai
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import function_app  # noqa: E402


def make_request():
    """Cria uma requisição HTTP falsa (GET), igual a que o Azure Functions receberia de verdade."""
    return func.HttpRequest(
        method="GET",
        url="/api/counter",
        headers={},
        params={},
        body=None,
    )


@patch.dict(os.environ, {"COSMOS_CONNECTION_STRING": "fake-connection-string"})
@patch("function_app.TableServiceClient")
def test_counter_increments_existing_visitor(mock_table_service_client):
    """
    Cenário: já existe uma entidade com Count = 5.
    Esperado: a função deve incrementar para 6 e retornar {"count": 6}.
    """
    mock_table_client = MagicMock()
    mock_table_client.get_entity.return_value = {
        "PartitionKey": "visits",
        "RowKey": "count",
        "Count": 5,
    }
    mock_table_service_client.from_connection_string.return_value.get_table_client.return_value = mock_table_client

    request = make_request()
    response = function_app.counter(request)

    body = json.loads(response.get_body())

    assert response.status_code == 200
    assert body["count"] == 6
    mock_table_client.upsert_entity.assert_called_once()


@patch.dict(os.environ, {"COSMOS_CONNECTION_STRING": "fake-connection-string"})
@patch("function_app.TableServiceClient")
def test_counter_creates_first_visitor(mock_table_service_client):
    """
    Cenário: a entidade ainda não existe no banco (primeira visita).
    Esperado: a função deve criar a entidade com Count = 1.
    """
    mock_table_client = MagicMock()
    mock_table_client.get_entity.side_effect = Exception("Entidade não encontrada")
    mock_table_service_client.from_connection_string.return_value.get_table_client.return_value = mock_table_client

    request = make_request()
    response = function_app.counter(request)

    body = json.loads(response.get_body())

    assert response.status_code == 200
    assert body["count"] == 1
    mock_table_client.upsert_entity.assert_called_once()


@patch.dict(os.environ, {"COSMOS_CONNECTION_STRING": "fake-connection-string"})
@patch("function_app.TableServiceClient")
def test_counter_returns_500_on_unexpected_error(mock_table_service_client):
    """
    Cenário: o banco de dados falha de forma inesperada ao tentar salvar (upsert).
    Esperado: a função deve retornar status 500 com uma mensagem de erro amigável.
    """
    mock_table_client = MagicMock()
    mock_table_client.get_entity.return_value = {
        "PartitionKey": "visits",
        "RowKey": "count",
        "Count": 10,
    }
    mock_table_client.upsert_entity.side_effect = Exception("Falha de conexão simulada")
    mock_table_service_client.from_connection_string.return_value.get_table_client.return_value = mock_table_client

    request = make_request()
    response = function_app.counter(request)

    body = json.loads(response.get_body())

    assert response.status_code == 500
    assert "error" in body
