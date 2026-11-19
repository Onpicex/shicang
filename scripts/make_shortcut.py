#!/usr/bin/python3
"""生成 iPhone 快捷指令「存到拾藏」（未签名 → 再用 shortcuts sign 签名）。

做的事：分享表单收到链接/文字（或从主屏点开时读剪贴板）
  → 词典 {share_text, device, captured_at, from}
  → 存成 快捷指令 iCloud 文件夹/拾藏Inbox/拾藏-<时间>.json
  → 通知「已存好」
Mac 上的拾藏监听这个文件夹，收进队列后删掉文件。手机上不联网也能存，等同步。

用法：/usr/bin/python3 scripts/make_shortcut.py <输出.shortcut>
"""
import plistlib
import sys
import uuid

OBJ = "￼"


def uid():
    return str(uuid.uuid4()).upper()


def tokens(parts):
    """parts: 字符串或 dict(变量)；拼成 WFTextTokenString"""
    s, att = "", {}
    for p in parts:
        if isinstance(p, str):
            s += p
        else:
            att["{%d, 1}" % (len(s.encode("utf-16-le")) // 2)] = p     # 位置按 UTF-16 计
            s += OBJ
    return {"Value": {"string": s, "attachmentsByRange": att}, "WFSerializationType": "WFTextTokenString"}


def out(u, name):
    return {"OutputUUID": u, "Type": "ActionOutput", "OutputName": name}


def attachment(v):
    return {"Value": v, "WFSerializationType": "WFTextTokenAttachment"}


def text_item(key, parts):
    return {"WFItemType": 0, "WFKey": tokens([key]), "WFValue": tokens(parts)}


U_DEV, U_ISO, U_STAMP, U_DICT, U_NAME, U_SAVE = (uid() for _ in range(6))
INPUT = {"Type": "ExtensionInput"}
NOW = {"Type": "CurrentDate"}

actions = [
    {"WFWorkflowActionIdentifier": "is.workflow.actions.getdevicedetails",
     "WFWorkflowActionParameters": {"WFDeviceDetail": "Device Name", "UUID": U_DEV}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.format.date",
     "WFWorkflowActionParameters": {"WFDateFormatStyle": "ISO 8601", "WFISO8601IncludeTime": True,
                                    "WFDate": tokens([NOW]), "UUID": U_ISO}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.format.date",
     "WFWorkflowActionParameters": {"WFDateFormatStyle": "Custom", "WFDateFormat": "yyyyMMdd-HHmmss",
                                    "WFDate": tokens([NOW]), "UUID": U_STAMP}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.dictionary",
     "WFWorkflowActionParameters": {"UUID": U_DICT, "WFItems": {"Value": {"WFDictionaryFieldValueItems": [
         text_item("share_text", [INPUT]),
         text_item("device", [out(U_DEV, "设备详细信息")]),
         text_item("captured_at", [out(U_ISO, "格式化的日期")]),
         text_item("from", ["iPhone 快捷指令"]),
     ]}, "WFSerializationType": "WFDictionaryFieldValue"}}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.setitemname",
     "WFWorkflowActionParameters": {"UUID": U_NAME, "WFInput": attachment(out(U_DICT, "词典")),
                                    "WFName": tokens(["拾藏-", out(U_STAMP, "格式化的日期"), ".json"])}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
     "WFWorkflowActionParameters": {"UUID": U_SAVE, "WFInput": attachment(out(U_NAME, "重新命名的项目")),
                                    "WFAskWhereToSave": False, "WFSaveFileOverwrite": False,
                                    "WFFileDestinationPath": "拾藏Inbox/"}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.notification",
     "WFWorkflowActionParameters": {"WFNotificationActionTitle": "拾藏",
                                    "WFNotificationActionBody": "已存好，Mac 上的拾藏会自动抓取",
                                    "WFNotificationActionSound": False}},
]

shortcut = {
    "WFWorkflowClientVersion": "2700.0.4",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4251333119, "WFWorkflowIconGlyphNumber": 61440},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowTypes": ["ActionExtension"],
    "WFWorkflowInputContentItemClasses": ["WFURLContentItem", "WFStringContentItem", "WFRichTextContentItem"],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowNoInputBehavior": {"Name": "WFWorkflowNoInputBehaviorGetClipboard", "Parameters": {}},
    "WFWorkflowOutputContentItemClasses": [],
    "WFQuickActionSurfaces": [],
    "WFWorkflowActions": actions,
}

with open(sys.argv[1], "wb") as f:
    plistlib.dump(shortcut, f, fmt=plistlib.FMT_BINARY)
print("已生成", sys.argv[1])
