#include <metal_stdlib>
using namespace metal;

// MARK: - AspectFill模式的缩略图生成着色器 (像iPhone Photos)
kernel void generateThumbnailSimple(texture2d<float, access::read> inputTexture [[texture(0)]],
                                   texture2d<float, access::write> outputTexture [[texture(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    
    // 边界检查
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 获取纹理尺寸
    float2 inputSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    
    // 计算宽高比
    float inputAspect = inputSize.x / inputSize.y;
    float outputAspect = outputSize.x / outputSize.y;
    
    // AspectFill模式：选择较大的缩放比例，确保填满整个输出区域
    float scaleX = outputSize.x / inputSize.x;
    float scaleY = outputSize.y / inputSize.y;
    float scale = max(scaleX, scaleY);  // 选择较大的缩放比例
    
    // 计算缩放后的输入图片尺寸
    float2 scaledInputSize = inputSize * scale;
    
    // 计算居中偏移（用于裁剪）
    float2 offset = (scaledInputSize - outputSize) * 0.5;
    
    // 当前像素在输出坐标系中的位置
    float2 outputCoord = float2(gid);
    
    // 映射到缩放后的输入坐标系
    float2 scaledInputCoord = outputCoord + offset;
    
    // 映射回原始输入坐标系
    float2 inputCoord = scaledInputCoord / scale;
    
    // 边界检查 - 确保在输入图片范围内
    if (inputCoord.x < 0.0 || inputCoord.x >= inputSize.x ||
        inputCoord.y < 0.0 || inputCoord.y >= inputSize.y) {
        // 超出范围的像素用黑色填充（理论上不应该发生）
        outputTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }
    
    // 高质量双线性插值采样
    float2 floorCoord = floor(inputCoord - 0.5);
    float2 t = inputCoord - 0.5 - floorCoord;
    
    // 计算四个采样点的坐标
    int2 coord00 = int2(floorCoord);
    int2 coord10 = coord00 + int2(1, 0);
    int2 coord01 = coord00 + int2(0, 1);
    int2 coord11 = coord00 + int2(1, 1);
    
    // 边界夹紧
    coord00 = clamp(coord00, int2(0), int2(inputSize) - 1);
    coord10 = clamp(coord10, int2(0), int2(inputSize) - 1);
    coord01 = clamp(coord01, int2(0), int2(inputSize) - 1);
    coord11 = clamp(coord11, int2(0), int2(inputSize) - 1);
    
    // 读取四个像素值
    float4 p00 = inputTexture.read(uint2(coord00));
    float4 p10 = inputTexture.read(uint2(coord10));
    float4 p01 = inputTexture.read(uint2(coord01));
    float4 p11 = inputTexture.read(uint2(coord11));
    
    // 双线性插值
    float4 p0 = mix(p00, p10, t.x);
    float4 p1 = mix(p01, p11, t.x);
    float4 result = mix(p0, p1, t.y);
    
    // 确保alpha通道正确
    result.a = 1.0;
    
    // 写入输出
    outputTexture.write(result, gid);
}
