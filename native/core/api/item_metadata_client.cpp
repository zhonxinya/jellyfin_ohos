/**
 * 条目元数据管理里**依赖 HTTP 客户端**的那一层。
 *
 * 单独成文件的原因与 `library_admin_client.cpp` 相同：主机侧单测只链接纯函数所在的
 * `item_metadata_api.cpp`（+ `url_util.cpp`），不需要把 `JellyfinApiClient` 拖进来的
 * socket / TLS 依赖一起编译。
 */

#include "item_metadata_api.h"

namespace jellyfin {
namespace api {

ApiResult getItemMetadata(JellyfinApiClient &client, const std::string &userId,
                          const std::string &itemId)
{
    ApiResult item = client.getJson(buildItemMetadataRequest(userId, itemId).path);
    if (!item.ok()) {
        return item;
    }

    ApiResult result;
    result.error.statusCode = 200;
    // 条目类型（`Movie` / `Series` / `Episode`…）：界面据此决定要不要给「识别」入口
    std::string itemType;
    if (item.data.is_object() && item.data.contains("Type") && item.data["Type"].is_string()) {
        itemType = item.data["Type"].get<std::string>();
    }
    result.data = nlohmann::json::object({
        // 条目**原文**：表单回填与整体回传都用它，core 不做裁剪（裁剪会丢字段，见头文件说明）
        {"item", item.data},
        {"editor", nlohmann::json::object()},
        {"editorError", ""},
        // 空串 = 服务端没有该类型的 RemoteSearch 端点（10.8 没有 Episode），界面隐藏「识别」
        {"remoteSearchType", remoteSearchTypeFor(itemType)},
        // 「锁定字段」多选的**取值来源**：界面只负责配中文名，枚举本身以服务端为准
        {"metadataFields", metadataFieldNames()},
    });

    // 编辑器信息只是下拉数据源（分级/国家/语言/外部 ID 定义）。拿不到时不该让整页打不开 ——
    // 字段还是能改的，只是下拉要退化成自由输入；所以把失败如实带出去，由界面提示
    ApiResult editor = client.getJson(buildMetadataEditorRequest(itemId).path);
    if (editor.ok()) {
        result.data["editor"] = normalizeMetadataEditorInfo(editor.data);
    } else {
        result.data["editorError"] =
            editor.error.message.empty() ? std::string("元数据选项读取失败") : editor.error.message;
    }
    return result;
}

ApiResult remoteSearch(JellyfinApiClient &client, const RemoteSearchQuery &query)
{
    const LibraryRequest request = buildRemoteSearchRequest(query);
    ApiResult result = client.postJson(request.path, request.body);
    if (!result.ok()) {
        return result;
    }
    result.data = normalizeRemoteSearchResults(result.data);
    return result;
}

} // namespace api
} // namespace jellyfin
