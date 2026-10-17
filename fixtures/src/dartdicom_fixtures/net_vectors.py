"""pynetdicom's encodings of the PDUs and DIMSE messages dartdicom_net
sends and answers, as test vectors (I-12), and its state table (I-13).

`net/vectors.json` lists each vector's inputs beside pynetdicom's bytes, so
the Dart test builds the same PDU from the same inputs and compares byte
for byte. `net/transition_table.json` is pynetdicom's `TRANSITION_TABLE`,
each action with its nominal next state.
"""

from __future__ import annotations

import json
from io import BytesIO
from pathlib import Path
from typing import Any

import pynetdicom
from pydicom.dataset import Dataset
from pydicom.filebase import DicomBytesIO
from pydicom.filewriter import write_dataset
from pynetdicom import dimse_messages, dimse_primitives
from pynetdicom.fsm import ACTIONS, TRANSITION_TABLE
from pynetdicom.pdu import (
    A_ABORT_RQ,
    A_ASSOCIATE_AC,
    A_ASSOCIATE_RJ,
    A_ASSOCIATE_RQ,
    A_RELEASE_RP,
    A_RELEASE_RQ,
    P_DATA_TF,
)
from pynetdicom.pdu_primitives import (
    A_ABORT,
    A_ASSOCIATE,
    A_P_ABORT,
    P_DATA,
    AsynchronousOperationsWindowNegotiation,
    ImplementationClassUIDNotification,
    ImplementationVersionNameNotification,
    MaximumLengthNotification,
    SCP_SCU_RoleSelectionNegotiation,
)
from pynetdicom.presentation import PresentationContext

VECTORS = "vectors.json"
TABLE = "transition_table.json"

_APPLICATION_CONTEXT = "1.2.840.10008.3.1.1.1"
_VERIFICATION = "1.2.840.10008.1.1"
_STUDY_FIND = "1.2.840.10008.5.1.4.1.2.2.1"
_STUDY_MOVE = "1.2.840.10008.5.1.4.1.2.2.2"
_STUDY_GET = "1.2.840.10008.5.1.4.1.2.2.3"
_CT_STORAGE = "1.2.840.10008.5.1.4.1.1.2"
_EXPLICIT = "1.2.840.10008.1.2.1"
_IMPLICIT = "1.2.840.10008.1.2"
_INSTANCE = "2.25.1234567890123456789"


def write(out_dir: Path) -> list[Path]:
    """Writes the vectors and the state table into `out_dir`."""
    out_dir.mkdir(parents=True, exist_ok=True)
    vectors = {"pynetdicom": pynetdicom.__version__, "vectors": _vectors()}
    paths = [out_dir / VECTORS, out_dir / TABLE]
    paths[0].write_text(json.dumps(vectors, indent=1) + "\n")
    paths[1].write_text(json.dumps(_table(), indent=1, sort_keys=True) + "\n")
    return paths


def describe(name: str) -> str:
    """The PROVENANCE note for one of the files [write] produces."""
    return {
        VECTORS: "PDUs and DIMSE messages with their inputs, for I-12",
        TABLE: "the PS3.8 state table as pynetdicom encodes it, for I-13",
    }[name]


# ── PDUs ─────────────────────────────────────────────────────────────────────


def _user_information(user: dict[str, Any]) -> list[Any]:
    """pynetdicom's user-information items, in dartdicom's order: 51, 52,
    55, the 54 role items, then 53 (as pynetdicom's own association sends)."""
    items: list[Any] = []
    max_length = MaximumLengthNotification()
    max_length.maximum_length_received = user["max_length"]
    items.append(max_length)
    class_uid = ImplementationClassUIDNotification()
    class_uid.implementation_class_uid = user["class_uid"]
    items.append(class_uid)
    if "version" in user:
        version = ImplementationVersionNameNotification()
        version.implementation_version_name = user["version"]
        items.append(version)
    for role in user.get("roles", []):
        selection = SCP_SCU_RoleSelectionNegotiation()
        selection.sop_class_uid = role["sop_class"]
        selection.scu_role = role["scu"]
        selection.scp_role = role["scp"]
        items.append(selection)
    if "async" in user:
        window = AsynchronousOperationsWindowNegotiation()
        invoked, performed = user["async"]
        window.maximum_number_operations_invoked = invoked
        window.maximum_number_operations_performed = performed
        items.append(window)
    return items


def _associate_rq(
    called: str, calling: str, contexts: list[dict[str, Any]], user: dict[str, Any]
) -> dict[str, Any]:
    primitive = A_ASSOCIATE()
    primitive.application_context_name = _APPLICATION_CONTEXT
    primitive.called_ae_title = called
    primitive.calling_ae_title = calling
    for c in contexts:
        context = PresentationContext()
        context.context_id = c["id"]
        context.abstract_syntax = c["abstract_syntax"]
        context.transfer_syntax = c["transfer_syntaxes"]
        primitive.presentation_context_definition_list.append(context)
    primitive.user_information = _user_information(user)
    pdu = A_ASSOCIATE_RQ()
    pdu.from_primitive(primitive)
    return {
        "called": called,
        "calling": calling,
        "contexts": contexts,
        "user": user,
        "hex": pdu.encode().hex(),
    }


def _associate_ac(
    called: str, calling: str, results: list[dict[str, Any]], user: dict[str, Any]
) -> dict[str, Any]:
    primitive = A_ASSOCIATE()
    primitive.application_context_name = _APPLICATION_CONTEXT
    primitive.called_ae_title = called
    primitive.calling_ae_title = calling
    primitive.result = 0
    for r in results:
        context = PresentationContext()
        context.context_id = r["id"]
        context.result = r["result"]
        context.transfer_syntax = [r["transfer_syntax"]]
        primitive.presentation_context_definition_results_list.append(context)
    primitive.user_information = _user_information(user)
    pdu = A_ASSOCIATE_AC()
    pdu.from_primitive(primitive)
    return {
        "called": called,
        "calling": calling,
        "results": results,
        "user": user,
        "hex": pdu.encode().hex(),
    }


def _associate_rj(result: int, source: int, reason: int) -> dict[str, Any]:
    primitive = A_ASSOCIATE()
    primitive.result = result
    primitive.result_source = source
    primitive.diagnostic = reason
    pdu = A_ASSOCIATE_RJ()
    pdu.from_primitive(primitive)
    return {
        "result": result,
        "source": source,
        "reason": reason,
        "hex": pdu.encode().hex(),
    }


def _p_data_tf(pdvs: list[dict[str, Any]]) -> dict[str, Any]:
    primitive = P_DATA()
    for pdv in pdvs:
        header = (1 if pdv["command"] else 0) | (2 if pdv["last"] else 0)
        primitive.presentation_data_value_list.append(
            (pdv["context"], bytes([header]) + bytes.fromhex(pdv["data"]))
        )
    pdu = P_DATA_TF()
    pdu.from_primitive(primitive)
    return {"pdvs": pdvs, "hex": pdu.encode().hex()}


def _abort(source: int, reason: int) -> dict[str, Any]:
    pdu = A_ABORT_RQ()
    if source == 0:
        primitive: Any = A_ABORT()
        primitive.abort_source = 0
    else:
        primitive = A_P_ABORT()
        primitive.provider_reason = reason
    pdu.from_primitive(primitive)
    return {"source": source, "reason": reason, "hex": pdu.encode().hex()}


def _pdus() -> list[dict[str, Any]]:
    user = {"max_length": 16384, "class_uid": "1.2.3.4.5", "version": "DARTDICOM_010"}
    echo = [
        {
            "id": 1,
            "abstract_syntax": _VERIFICATION,
            "transfer_syntaxes": [_EXPLICIT, _IMPLICIT],
        }
    ]
    retrieve = [
        {
            "id": 1,
            "abstract_syntax": _STUDY_GET,
            "transfer_syntaxes": [_EXPLICIT, _IMPLICIT],
        },
        {
            "id": 3,
            "abstract_syntax": _CT_STORAGE,
            "transfer_syntaxes": [_EXPLICIT, _IMPLICIT],
        },
    ]
    roles = [{"sop_class": _CT_STORAGE, "scu": False, "scp": True}]
    return [
        {
            "name": "A-ASSOCIATE-RQ, one context",
            "kind": "associate_rq",
            **_associate_rq("ORTHANC", "DARTDICOM", echo, user),
        },
        {
            "name": "A-ASSOCIATE-RQ, role selection",
            "kind": "associate_rq",
            **_associate_rq("ORTHANC", "DARTDICOM", retrieve, {**user, "roles": roles}),
        },
        {
            "name": "A-ASSOCIATE-RQ, async window, no version name",
            "kind": "associate_rq",
            **_associate_rq(
                "PACS",
                "A",
                echo,
                {"max_length": 0, "class_uid": "1.2.3.4.5", "async": [1, 1]},
            ),
        },
        {
            "name": "A-ASSOCIATE-AC, accepted and rejected contexts",
            "kind": "associate_ac",
            **_associate_ac(
                "ORTHANC",
                "DARTDICOM",
                [
                    {"id": 1, "result": 0, "transfer_syntax": _EXPLICIT},
                    {"id": 3, "result": 4, "transfer_syntax": _EXPLICIT},
                ],
                {**user, "roles": roles, "async": [1, 1]},
            ),
        },
        {
            "name": "A-ASSOCIATE-RJ, calling AE not recognized",
            "kind": "associate_rj",
            **_associate_rj(1, 1, 3),
        },
        {
            "name": "A-ASSOCIATE-RJ, transient, local limit",
            "kind": "associate_rj",
            **_associate_rj(2, 3, 2),
        },
        {
            "name": "P-DATA-TF, two PDVs",
            "kind": "p_data_tf",
            **_p_data_tf(
                [
                    {"context": 1, "command": True, "last": True, "data": "0800"},
                    {"context": 3, "command": False, "last": False, "data": "01020304"},
                ]
            ),
        },
        {
            "name": "A-RELEASE-RQ",
            "kind": "release_rq",
            "hex": A_RELEASE_RQ().encode().hex(),
        },
        {
            "name": "A-RELEASE-RP",
            "kind": "release_rp",
            "hex": A_RELEASE_RP().encode().hex(),
        },
        {"name": "A-ABORT, service user", "kind": "abort", **_abort(0, 0)},
        {"name": "A-ABORT, provider, unexpected PDU", "kind": "abort", **_abort(2, 2)},
    ]


# ── DIMSE messages ───────────────────────────────────────────────────────────


def _identifier(**elements: Any) -> bytes:
    """A small dataset in Implicit VR Little Endian, as pydicom writes it."""
    ds = Dataset()
    for keyword, value in elements.items():
        setattr(ds, keyword, value)
    out = DicomBytesIO()
    out.is_little_endian = True
    out.is_implicit_VR = True
    write_dataset(out, ds)
    return out.getvalue()


def _message(
    name: str,
    params: dict[str, Any],
    *,
    context: int = 1,
    max_pdu: int = 16384,
    dataset: bytes | None = None,
) -> dict[str, Any]:
    """`name` (e.g. "C-ECHO-RQ") with primitive `params`, as pynetdicom
    fragments it into P-DATA-TF PDUs."""
    service, kind = name.rsplit("-", 1)
    primitive = getattr(dimse_primitives, service.replace("-", "_"))()
    for key, value in params.items():
        setattr(primitive, key, value)
    if dataset is not None:
        field = "DataSet" if service == "C-STORE" else "Identifier"
        setattr(primitive, field, BytesIO(dataset))
    message = getattr(dimse_messages, name.replace("-", "_"))()
    message.primitive_to_message(primitive)
    pdus = []
    for p_data in message.encode_msg(context, max_pdu):
        pdu = P_DATA_TF()
        pdu.from_primitive(p_data)
        pdus.append(pdu.encode().hex())
    command = [
        {"tag": f"{int(e.tag):08X}", "vr": e.VR, "value": e.value}
        for e in message.command_set
        if int(e.tag) != 0x00000000  # the group length: the encoder's job
    ]
    vector: dict[str, Any] = {
        "name": name,
        "kind": "dimse",
        "context": context,
        "max_pdu": max_pdu,
        "command": command,
        "pdus": pdus,
    }
    if dataset is not None:
        vector["dataset"] = dataset.hex()
    return vector


def _dimse() -> list[dict[str, Any]]:
    find = _identifier(QueryRetrieveLevel="STUDY", StudyInstanceUID="")
    match = _identifier(QueryRetrieveLevel="STUDY", StudyInstanceUID="1.2.3")
    get = _identifier(QueryRetrieveLevel="SERIES", SeriesInstanceUID="1.2.3.4")
    instance = _identifier(
        SOPClassUID=_CT_STORAGE,
        SOPInstanceUID=_INSTANCE,
        PatientName="Synthetic^Patient",
    )
    counts = {
        "NumberOfRemainingSuboperations": 2,
        "NumberOfCompletedSuboperations": 1,
        "NumberOfFailedSuboperations": 0,
        "NumberOfWarningSuboperations": 0,
    }
    final = {
        "NumberOfCompletedSuboperations": 3,
        "NumberOfFailedSuboperations": 0,
        "NumberOfWarningSuboperations": 0,
    }
    return [
        _message("C-ECHO-RQ", {"MessageID": 1, "AffectedSOPClassUID": _VERIFICATION}),
        _message(
            "C-ECHO-RSP",
            {
                "MessageIDBeingRespondedTo": 1,
                "AffectedSOPClassUID": _VERIFICATION,
                "Status": 0x0000,
            },
        ),
        _message(
            "C-FIND-RQ",
            {"MessageID": 2, "AffectedSOPClassUID": _STUDY_FIND, "Priority": 0},
            dataset=find,
        ),
        _message(
            "C-FIND-RSP",
            {
                "MessageIDBeingRespondedTo": 2,
                "AffectedSOPClassUID": _STUDY_FIND,
                "Status": 0xFF00,
            },
            dataset=match,
        ),
        _message(
            "C-FIND-RSP",
            {
                "MessageIDBeingRespondedTo": 2,
                "AffectedSOPClassUID": _STUDY_FIND,
                "Status": 0x0000,
            },
        ),
        _message(
            "C-GET-RQ",
            {"MessageID": 3, "AffectedSOPClassUID": _STUDY_GET, "Priority": 0},
            dataset=get,
        ),
        _message(
            "C-GET-RSP",
            {
                "MessageIDBeingRespondedTo": 3,
                "AffectedSOPClassUID": _STUDY_GET,
                "Status": 0xFF00,
                **counts,
            },
        ),
        _message(
            "C-GET-RSP",
            {
                "MessageIDBeingRespondedTo": 3,
                "AffectedSOPClassUID": _STUDY_GET,
                "Status": 0x0000,
                **final,
            },
        ),
        _message(
            "C-MOVE-RQ",
            {
                "MessageID": 4,
                "AffectedSOPClassUID": _STUDY_MOVE,
                "Priority": 0,
                "MoveDestination": "DARTDICOM",
            },
            dataset=get,
        ),
        _message(
            "C-MOVE-RSP",
            {
                "MessageIDBeingRespondedTo": 4,
                "AffectedSOPClassUID": _STUDY_MOVE,
                "Status": 0xFF00,
                **counts,
            },
        ),
        _message(
            "C-STORE-RQ",
            {
                "MessageID": 5,
                "AffectedSOPClassUID": _CT_STORAGE,
                "AffectedSOPInstanceUID": _INSTANCE,
                "Priority": 0,
            },
            context=3,
            dataset=instance,
        ),
        _message(
            "C-STORE-RQ",
            {
                "MessageID": 6,
                "AffectedSOPClassUID": _CT_STORAGE,
                "AffectedSOPInstanceUID": _INSTANCE,
                "Priority": 0,
                "MoveOriginatorApplicationEntityTitle": "DARTDICOM",
                "MoveOriginatorMessageID": 4,
            },
            context=3,
            max_pdu=64,
            dataset=instance,
        ),
        _message(
            "C-STORE-RSP",
            {
                "MessageIDBeingRespondedTo": 5,
                "AffectedSOPClassUID": _CT_STORAGE,
                "AffectedSOPInstanceUID": _INSTANCE,
                "Status": 0x0000,
            },
            context=3,
        ),
        _message("C-CANCEL-RQ", {"MessageIDBeingRespondedTo": 2}),
        _message(
            "C-STORE-RQ",
            {
                "MessageID": 7,
                "AffectedSOPClassUID": _CT_STORAGE,
                "AffectedSOPInstanceUID": _INSTANCE,
                "Priority": 0,
            },
            context=3,
            max_pdu=0,
            dataset=instance,
        ),
    ]


def _vectors() -> list[dict[str, Any]]:
    return _pdus() + _dimse()


# ── The state table ──────────────────────────────────────────────────────────


def _table() -> dict[str, dict[str, list[str]]]:
    """{state: {event: [action, nominal next state]}} for every cell
    PS3.8 fills; the cells absent are blank."""
    table: dict[str, dict[str, list[str]]] = {}
    for (event, state), action in TRANSITION_TABLE.items():
        table.setdefault(state, {})[event] = [action, ACTIONS[action][2]]
    return table
