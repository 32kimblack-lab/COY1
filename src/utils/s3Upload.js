// S3 Upload Utility
const AWS = require('aws-sdk');
const { v4: uuidv4 } = require('uuid');

// Configure AWS S3
const s3 = new AWS.S3({
  accessKeyId: process.env.AWS_ACCESS_KEY_ID,
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
  region: process.env.AWS_REGION || 'us-east-2'
});

const BUCKET_NAME = process.env.AWS_S3_BUCKET_NAME || 'coy-images-2025';

/**
 * Upload image to S3
 * @param {Buffer} imageBuffer - Image data buffer
 * @param {String} folder - Folder path in S3 (e.g., 'profiles', 'collections', 'posts')
 * @param {String} mimeType - MIME type (e.g., 'image/jpeg', 'image/png')
 * @returns {Promise<String>} - S3 URL of uploaded image
 */
async function uploadToS3(imageBuffer, folder, mimeType = 'image/jpeg') {
  try {
    // Determine file extension based on mime type
    let fileExtension = 'jpg';
    if (mimeType === 'image/png') {
      fileExtension = 'png';
    } else if (mimeType && mimeType.startsWith('video/')) {
      // Handle video types
      if (mimeType.includes('mp4')) {
        fileExtension = 'mp4';
      } else if (mimeType.includes('mov')) {
        fileExtension = 'mov';
      } else {
        fileExtension = 'mp4'; // Default for videos
      }
    }
    
    const fileName = `${folder}/${uuidv4()}.${fileExtension}`;
    
    const params = {
      Bucket: BUCKET_NAME,
      Key: fileName,
      Body: imageBuffer,
      ContentType: mimeType,
      ACL: 'public-read' // Make files publicly accessible
    };

    const result = await s3.upload(params).promise();
    return result.Location;
  } catch (error) {
    console.error('S3 upload error:', error);
    throw new Error(`Failed to upload to S3: ${error.message}`);
  }
}

/**
 * Parse multipart form data to extract files and fields
 * Note: This is a simplified parser. For production, consider using multer or busboy
 */
function parseMultipartFormData(body, boundary) {
  const parts = body.split(`--${boundary}`);
  const fields = {};
  const files = {};

  for (const part of parts) {
    if (!part || part === '--' || part.trim() === '') continue;

    const [headers, ...bodyParts] = part.split('\r\n\r\n');
    const content = bodyParts.join('\r\n\r\n').replace(/\r\n--$/, '');

    // Parse headers
    const contentDisposition = headers.match(/Content-Disposition:.*name="([^"]+)"/);
    const contentType = headers.match(/Content-Type:\s*(.+)/);

    if (contentDisposition) {
      const fieldName = contentDisposition[1];
      const isFile = headers.includes('filename=');

      if (isFile && contentType) {
        // It's a file
        const filenameMatch = headers.match(/filename="([^"]+)"/);
        files[fieldName] = {
          buffer: Buffer.from(content, 'binary'),
          mimetype: contentType[1].trim(),
          filename: filenameMatch ? filenameMatch[1] : fieldName
        };
      } else {
        // It's a regular field
        fields[fieldName] = content.trim();
      }
    }
  }

  return { fields, files };
}

module.exports = { uploadToS3, parseMultipartFormData };

