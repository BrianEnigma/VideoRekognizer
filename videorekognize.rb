#!/usr/bin/env ruby

require 'getoptlong'
require 'yaml'
require 'aws-sdk'

def timecode_string(seconds)
    hours = (seconds / (60 * 60)).to_i
    seconds = seconds % (60 * 60)
    minutes = (seconds / 60).to_i
    seconds = seconds % 60
    return sprintf("%02u:%02u:%02u.000", hours, minutes, seconds)
end

def extract_frames(video_filename, extract_period, tmp_location)
    seconds = 0
    counter = 0
    print("Extracting video frames...\n")
    while true
        timecode = timecode_string(seconds)
        filename = sprintf("%s/img%05d.png", tmp_location, counter)
        cmd = "ffmpeg -loglevel 16 -ss #{timecode} -i \"#{video_filename}\" -frames:v 1 \"#{filename}\""
        print("#{timecode}\r")
        rc = Kernel.system(cmd)
        break if (true != rc)
        break if (!File.exists?(filename))
        seconds += extract_period
        counter += 1
    end
    count = `ls #{tmp_location}/*.png | wc -l`
    count = count.to_i
    print("Extracted #{count} video frames\n")
end

def remove_remote_frames(bucket_name)
    s3 = Aws::S3::Client.new
    print("Cleaning up stale S3 objects...\n")
    s3.list_objects_v2(bucket: bucket_name, prefix: 'img').contents.each { |object|
        #p object
        s3.delete_object(bucket: bucket_name, key: object.key)
    }
end

def upload_frames(tmp_location, bucket_name)
    s3 = Aws::S3::Client.new
    Dir.new(tmp_location).each { |filename|
        #p filename
        if (0 == filename.index('img') && filename.index('.png') == filename.length - 4)
            print("Uploading #{filename}...\n")
            f = File.new("#{tmp_location}/#{filename}", 'rb')
            s3.put_object(bucket: bucket_name, key: filename, body: f.read)
            f.close
        end
    }    
end

def time_string(seconds)
    hours = (seconds / (60 * 60)).to_i
    seconds = seconds % (60 * 60)
    minutes = (seconds / 60).to_i
    seconds = seconds % 60
    return sprintf("%uh:%02um:%02us", hours, minutes, seconds)
end

def rekognize_frames(bucket_name, extract_period)
    s3 = Aws::S3::Client.new
    rekognition = Aws::Rekognition::Client.new
    seconds = 0
    result = Array.new
 
    s3.list_objects(bucket: bucket_name).contents.each do |object|
        #p object
        labels = rekognition.detect_labels({
                image: {
                    s3_object: {
                        bucket: bucket_name, name: object.key
                    }
                },max_labels:20, min_confidence: 50
            }).labels
        label_string = ''
        labels.map { |l| 
            label_string += "'#{l.name}:#{l.confidence.to_i}%' "
        }
        print("#{object.key} @ #{time_string(seconds)} : #{label_string}\n")
        result << [object.key, seconds, label_string, labels]
        seconds += extract_period
    end
    return result
end

def generate_html(tmp_location, rekognize_results)
    `rm -rf ./output`
    `mkdir ./output`
    `cp #{tmp_location}/img*.png ./output/`
    
    outfile = File.open('./output/index.json', 'w')
    outfile << "[\n"
    first = true
    rekognize_results.each { |result|
        filename = result[0]
        seconds = result[1]
        label_string = result[2]
        labels = result[3]
        outfile << "\t"
        if (first)
            first = false
        else
            outfile << ","
        end
        outfile << "{\n"
        outfile << "\t\t\"filename\": \"#{filename}\",\n"
        outfile << "\t\t\"seconds\": #{seconds},\n"
        outfile << "\t\t\"time\": \"#{time_string(seconds)}\",\n"
        outfile << "\t\t\"allLabels\": \"#{label_string}\"\n"
        # TODO: Make 'labels' available as distinct fields.
        outfile << "\t}\n"
    }
    outfile << "]\n"
    outfile.close
    
    outfile = File.open('./output/index.html', 'w')
    outfile << "<html><head></head><style>\n"
    outfile << "tr.row {margin-bottom:1em;}\n"
    outfile << "td {vertical-align:top;}\n"
    outfile << "td.thumbnail {width:50%;}\n"
    outfile << "td.metadata {width:50%; padding-left:2em;}\n"
    outfile << "div.timecode {font-weight:bold; text-decoration:underline;}\n"
    outfile << "ul {list-style: none; padding-left:0; margin-top:0;}\n"
    outfile << "img {max-width:100%;}\n"
    outfile << "</style><body>\n"
    outfile << "<table>\n"
    rekognize_results.each { |result|
        filename = result[0]
        seconds = result[1]
        label_string = result[2]
        labels = result[3]
        outfile << "<tr class=\"row\"><td class=\"thumbnail\">\n"
        outfile << "<img src=\"#{filename}\" />\n"
        outfile << "</td><td class=\"metadata\">\n"
        outfile << "<div class=\"timecode\">#{time_string(seconds)}</div>\n"
        outfile << "<div class=\"labels\"><ul>"
        labels.each { |entry|
            outfile << "<li>#{entry.name} : #{entry.confidence.to_i}%</li>\n"
        }
        outfile << "</ul></div>\n"
        outfile << "</td></tr>\n"
    }
    outfile << "</table>\n"
    outfile << "</body></html>\n"
    outfile.close
    
end

def is_ffmpeg_present()
    result = `which ffmpeg`
    return false if nil == result || result.empty?
    return true
end

def print_help(error_message)
    print("#{error_message}\n") if nil != error_message
    puts <<-EOF
videorekognizer.rb
{copyright stuff}

videorekognizer.rb [options} {video_filename}
    
Options include:
--help                      This help text.
--no-frame-extract          Don't extract video frames.
--no-upload                 Don't upload extracted video frames.
--extract-period {seconds}  Extract a video frame every this many seconds.
EOF
end

opts = GetoptLong.new(
    ['--help', '-h', GetoptLong::NO_ARGUMENT],
    ['--no-frame-extract', GetoptLong::NO_ARGUMENT],
    ['--no-upload', GetoptLong::NO_ARGUMENT],
    ['--no-recognize', GetoptLong::NO_ARGUMENT],
    ['--no-html', GetoptLong::NO_ARGUMENT],
    ['--extract-period', GetoptLong::REQUIRED_ARGUMENT]
)

########## DEFAULTS

do_frame_extract = true
do_upload = true
do_rekognize = true
do_html = true
bucket_name = nil
region  = 'us-west-2'
video_filename = nil;
extract_period = 10
tmp_location = '/tmp/video_recognizer'

########## PARSE INPUTS

opts.each { |opt, arg|
    case opt
    when '--help'
        print_help(nil)
        exit 1
    when '--no-frame-extract'
        do_frame_extract = false
    when '--no-upload'
        do_upload = false
    when '--no-recognize'
        do_rekognize = false
    when '--no-html'
        do_html = false
    when '--extract-period'
        extract_period = arg.to_i
    end
}

########## VALIDATE INPUTS

if (!is_ffmpeg_present())
    print_help("The ffmpeg executable is required")
    exit 1
end
if (ARGV.length != 1)
    print_help("Required video filename is missing")
    exit 1
end
if (extract_period <= 0)
    print_help("A positive nonzero --extract-period is required.")
    exit 1
end
video_filename = File.expand_path(ARGV[0])
if (!File.exists?(video_filename))
    print_help("Unable to open input video file")
    exit 1
end
if (!File.exists?('credentials.yml'))
    print_help("File credentials.yml does not exist. See credentials-sample.yml for a template.")
    exit 1
end

########## SECURITY, SETTINGS

credentials = YAML.load(File.read('credentials.yml'))
bucket_name = credentials['bucket_name']
region = credentials['region']
Aws.config.update(
    {
        region: region, 
        credentials: Aws::Credentials.new(credentials['access_key_id'],credentials['secret_access_key'])
    }
)

########## VALIDATE CONFIG.YML CONTENT

if (nil == bucket_name || bucket_name.empty?)
    print_help("File credentials.yml does not have a valid bucket name.")
    exit 1
end
if (nil == bucket_name || bucket_name.empty?)
    print_help("File credentials.yml does not have a valid region.")
    exit 1
end

########## DO THE THING

if (do_frame_extract)
    `rm -rf #{tmp_location}`
    Dir.mkdir(tmp_location)
    extract_frames(video_filename, extract_period, tmp_location)
end

if (do_upload)
    remove_remote_frames(bucket_name)
    upload_frames(tmp_location, bucket_name)
end

if (do_rekognize)
    rekognize_results = rekognize_frames(bucket_name, extract_period)
    if (do_html)
        generate_html(tmp_location, rekognize_results)
    end
end


