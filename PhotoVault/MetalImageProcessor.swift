import Foundation
import Metal
import MetalKit
import UIKit
import CoreGraphics

// MARK: - Metal GPU加速图片处理器 (可选加速器)
class MetalImageProcessor {
    static let shared: MetalImageProcessor? = {
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("MetalImageProcessor: Metal not supported, using CPU only")
            return nil
        }
        return MetalImageProcessor()
    }()
    
    // Metal核心组件
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureLoader: MTKTextureLoader
    private let pipelineState: MTLComputePipelineState
    
    private init?() {
        // 初始化Metal设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MetalImageProcessor: Metal device creation failed")
            return nil
        }
        
        guard let commandQueue = device.makeCommandQueue() else {
            print("MetalImageProcessor: Command queue creation failed")
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)
        
        // 创建着色器
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "generateThumbnailSimple") else {
            print("MetalImageProcessor: Shader function not found")
            return nil
        }
        
        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("MetalImageProcessor: Pipeline state creation failed: \(error)")
            return nil
        }
        
        print("MetalImageProcessor: Successfully initialized with device: \(device.name)")
    }
    
    // MARK: - 简化的GPU加速接口
    
    /// 尝试使用GPU生成缩略图，失败则返回nil让CPU处理
    func generateThumbnailIfPossible(from image: UIImage, targetSize: CGSize) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        do {
            // 使用正确的颜色空间和选项创建输入纹理
            let textureOptions: [MTKTextureLoader.Option: Any] = [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.shared.rawValue,
                .generateMipmaps: false,
                .SRGB: true  // 重要：保持sRGB颜色空间
            ]
            
            guard let inputTexture = try? textureLoader.newTexture(cgImage: cgImage, options: textureOptions) else {
                return nil
            }
            
            // 创建输出纹理 - 使用sRGB格式
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,  // 使用sRGB格式保持颜色正确
                width: Int(targetSize.width),
                height: Int(targetSize.height),
                mipmapped: false
            )
            outputDescriptor.usage = [.shaderWrite, .shaderRead]
            outputDescriptor.storageMode = .shared
            
            guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
                return nil
            }
            
            // 创建命令
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return nil
            }
            
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            
            // 计算线程组
            let threadgroupSize = MTLSizeMake(16, 16, 1)
            let threadgroupCount = MTLSizeMake(
                (outputTexture.width + 15) / 16,
                (outputTexture.height + 15) / 16,
                1
            )
            
            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
            
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            // 检查是否成功
            guard commandBuffer.status == .completed else {
                return nil
            }
            
            // 转换为UIImage
            return createUIImage(from: outputTexture)
            
        } catch {
            return nil
        }
    }
    
    private func createUIImage(from texture: MTLTexture) -> UIImage? {
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        let bufferSize = bytesPerRow * texture.height
        
        var imageBytes = [UInt8](repeating: 0, count: bufferSize)
        
        texture.getBytes(&imageBytes,
                        bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                        mipmapLevel: 0)
        
        // 使用sRGB颜色空间确保颜色正确
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &imageBytes,
                                    width: texture.width,
                                    height: texture.height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let cgImage = context.makeImage() else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - 性能监控
    static var isSupported: Bool {
        return shared != nil
    }
    
    var deviceName: String {
        return device.name
    }
}
