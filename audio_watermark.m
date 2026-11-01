clc;
clear;
close all;

%% ============================================================
%% IMAGE IN AUDIO WATERMARKING
%% FRAME ID + TMR + HAMMING + INTERLEAVING + AWGN NOISE
%% ============================================================

key = 12345;
INTERLEAVE_KEY = 54321; % Dedicated key for the interleaving shuffle
SNR_DB = 40; 
EMBED_BIT = 9; 

disp('======================================================');
disp(' IMAGE IN AUDIO WATERMARKING WITH ROBUST FRAME IDs');
disp('======================================================');

%% ============================================================
%% PARAMETERS
%% ============================================================

FRAME_SIZE = 250; % Increased slightly to accommodate the new header
START_PATTERN = [1 0 1 1 0 1 0 0 1 1 1 0 0 1 0 1];
END_PATTERN   = [0 1 0 0 1 0 1 1 0 0 0 1 1 0 1 0];

START_LEN = length(START_PATTERN);
END_LEN   = length(END_PATTERN);

FRAME_ID_BITS = 16; % Allows up to 65,535 frames
HEADER_LEN = FRAME_ID_BITS * 3; % 48 bits (Triple Modular Redundancy)

PAYLOAD_AREA = FRAME_SIZE - START_LEN - END_LEN - HEADER_LEN;
PAYLOAD_BITS_PER_FRAME = PAYLOAD_AREA;

%% ============================================================
%% 1. ENCODING & HAMMING (7,4)
%% ============================================================

disp('--- Starting Encoding Process ---');

[cover_audio, fs] = audioread('original.wav');
if size(cover_audio,2) > 1
    cover_audio = cover_audio(:,1);
end
cover_audio = cover_audio(:);
cover_int = int16(cover_audio * 32767);
audio_capacity = length(cover_int);

watermark = imread('cover.png');
if size(watermark,3) == 3
    watermark = rgb2gray(watermark);
end
watermark_binary = imbinarize(watermark);
[rows, cols] = size(watermark_binary);
wm_1d = double(watermark_binary(:)');
num_watermark_bits = length(wm_1d);

padding = mod(4 - mod(num_watermark_bits,4),4);
if padding == 4
    padding = 0;
end
wm_padded = [wm_1d zeros(1,padding)];
encoded_bits = hamming74_encode(wm_padded);
num_encoded_bits = length(encoded_bits);

%% ============================================================
%% 2. INTERLEAVING
%% ============================================================
disp('--- Interleaving Encoded Bits ---');
rng(INTERLEAVE_KEY, 'twister');
shuffle_map = randperm(num_encoded_bits);
interleaved_bits = encoded_bits(shuffle_map);

num_frames = ceil(num_encoded_bits / PAYLOAD_BITS_PER_FRAME);
required_samples = num_frames * FRAME_SIZE;

if required_samples > audio_capacity
    error(['Audio is too short. Required = ', num2str(required_samples)]);
end

%% ============================================================
%% 3. FRAME BASED EMBEDDING WITH FRAME ID
%% ============================================================

disp('--- Embedding Frames ---');
marked_int = cover_int;
data_index = 1;

for frame = 1:num_frames
    frame_start = (frame-1)*FRAME_SIZE + 1;
    frame_seed = key + frame * 1000;
    
    % Prepare Payload
    frame_payload = zeros(1,PAYLOAD_BITS_PER_FRAME);
    remaining_bits = num_encoded_bits - data_index + 1;
    bits_to_copy = min(PAYLOAD_BITS_PER_FRAME, remaining_bits);
    if bits_to_copy > 0
        frame_payload(1:bits_to_copy) = interleaved_bits(data_index : data_index + bits_to_copy - 1);
    end

    % 1. Insert START marker
    for k = 1:START_LEN
        loc = frame_start + k - 1;
        val = marked_int(loc);
        for b = 1:(EMBED_BIT-1), val = bitset(val, b, 0); end 
        val = bitset(val, EMBED_BIT-1, 1); 
        marked_int(loc) = bitset(val, EMBED_BIT, START_PATTERN(k));
    end
    
    % 2. Insert FRAME ID Header (Triple Modular Redundancy)
    frame_id_bin = dec2bin(frame, FRAME_ID_BITS) - '0'; % Convert ID to binary array
    header_bits = [frame_id_bin, frame_id_bin, frame_id_bin]; % Repeat 3 times
    
    header_start = frame_start + START_LEN;
    for k = 1:HEADER_LEN
        loc = header_start + k - 1;
        val = marked_int(loc);
        for b = 1:(EMBED_BIT-1), val = bitset(val, b, 0); end
        val = bitset(val, EMBED_BIT-1, 1);
        marked_int(loc) = bitset(val, EMBED_BIT, header_bits(k));
    end

    % 3. Insert Payload (Pseudorandom positions inside payload area)
    rng(frame_seed,'twister');
    payload_locations = randperm(PAYLOAD_AREA) + START_LEN + HEADER_LEN;
    for k = 1:PAYLOAD_BITS_PER_FRAME
        loc = frame_start + payload_locations(k) - 1;
        val = marked_int(loc);
        for b = 1:(EMBED_BIT-1), val = bitset(val, b, 0); end
        val = bitset(val, EMBED_BIT-1, 1);
        marked_int(loc) = bitset(val, EMBED_BIT, frame_payload(k));
    end

    % 4. Insert END marker 
    end_start = frame_start + START_LEN + HEADER_LEN + PAYLOAD_AREA;
    for k = 1:END_LEN
        loc = end_start + k - 1;
        val = marked_int(loc);
        for b = 1:(EMBED_BIT-1), val = bitset(val, b, 0); end
        val = bitset(val, EMBED_BIT-1, 1);
        marked_int(loc) = bitset(val, EMBED_BIT, END_PATTERN(k));
    end

    data_index = data_index + bits_to_copy;
end

audiowrite('marked_audio.wav',marked_int,fs);

%% ============================================================
%% 4. ADD AWGN NOISE ATTACK & SAVE METADATA
%% ============================================================

disp(['--- Applying Noise Attack (SNR = ', num2str(SNR_DB), ' dB) ---']);
marked_double = double(marked_int);
noisy_double = awgn(marked_double, SNR_DB, 'measured');
noisy_int = int16(noisy_double);
audiowrite('noisy_audio.wav', noisy_int, fs);
save('watermark_metadata.mat', 'key', 'INTERLEAVE_KEY', 'rows', 'cols', 'num_watermark_bits', ...
    'num_encoded_bits', 'padding', 'FRAME_SIZE', 'START_PATTERN', ...
    'END_PATTERN', 'START_LEN', 'END_LEN', 'PAYLOAD_AREA', ...
    'num_frames', 'PAYLOAD_BITS_PER_FRAME', 'EMBED_BIT', 'HEADER_LEN', 'FRAME_ID_BITS');

%% ============================================================
%% 5. DECODING (ADAPTIVE SEARCH)
%% ============================================================

disp('--- Performing Adaptive Correlation Search ---');
[wm_audio_int, ~] = audioread('noisy_audio.wav','native');
wm_audio_int = wm_audio_int(:);
audio_length = length(wm_audio_int);
data = load('watermark_metadata.mat');

audio_bits = double(bitget(wm_audio_int, data.EMBED_BIT))';

correlation_values = zeros(1, length(audio_bits) - data.START_LEN + 1);
pattern_signal = 2*data.START_PATTERN - 1;

for i = 1:length(correlation_values)
    segment = audio_bits(i : i + data.START_LEN - 1);
    segment_signal = 2*segment - 1;
    correlation_values(i) = sum(pattern_signal .* segment_signal) / data.START_LEN;
end

ADAPTIVE_THRESHOLD = max(0.35, max(correlation_values) - 0.35); 
found_frame_starts = [];
search_pos = 1;

while search_pos <= length(correlation_values)
    if correlation_values(search_pos) >= ADAPTIVE_THRESHOLD
        found_frame_starts(end+1) = search_pos;
        search_pos = search_pos + data.FRAME_SIZE; 
    else
        search_pos = search_pos + 1;
    end
end
disp(['Total detected frames = ', num2str(length(found_frame_starts))]);

%% ============================================================
%% 6. EXTRACT EACH FRAME & TMR VOTING
%% ============================================================

% Initialize with zeros (any dropped frames will naturally decode as static noise via Hamming)
extracted_interleaved_bits = zeros(1, data.num_encoded_bits);

for f = 1:length(found_frame_starts)
    frame_start = found_frame_starts(f);
    if frame_start + data.FRAME_SIZE - 1 > audio_length, continue; end

    % Extract Header (48 bits)
    header_locs = frame_start + data.START_LEN : frame_start + data.START_LEN + data.HEADER_LEN - 1;
    header_extracted = audio_bits(header_locs);
    
    % TMR Voting to fix bit errors in the Frame ID
    id1 = header_extracted(1:data.FRAME_ID_BITS);
    id2 = header_extracted(data.FRAME_ID_BITS+1 : 2*data.FRAME_ID_BITS);
    id3 = header_extracted(2*data.FRAME_ID_BITS+1 : 3*data.FRAME_ID_BITS);
    voted_id_bin = mode([id1; id2; id3], 1); % Bitwise majority vote
    extracted_frame_id = bin2dec(char(voted_id_bin + '0'));
    
    % Validate Frame ID
    if extracted_frame_id < 1 || extracted_frame_id > data.num_frames
        continue; % Corrupted ID beyond repair, drop frame
    end

    % Extract Payload using Correct Seed and Correct Global Position
    frame_seed = key + extracted_frame_id * 1000;
    rng(frame_seed,'twister');
    payload_locations = randperm(data.PAYLOAD_AREA) + data.START_LEN + data.HEADER_LEN;

    start_idx = (extracted_frame_id - 1) * data.PAYLOAD_BITS_PER_FRAME + 1;
    end_idx = min(start_idx + data.PAYLOAD_BITS_PER_FRAME - 1, data.num_encoded_bits);
    bits_in_this_frame = end_idx - start_idx + 1;
    
    frame_bits = zeros(1, bits_in_this_frame);
    for k = 1:bits_in_this_frame
        loc = frame_start + payload_locations(k) - 1;
        frame_bits(k) = audio_bits(loc);
    end
    
    % Place the payload securely in its absolute index
    extracted_interleaved_bits(start_idx : end_idx) = frame_bits;
end

%% ============================================================
%% 7. DE-INTERLEAVING & HAMMING DECODING
%% ============================================================
disp('--- De-interleaving Extracted Bits ---');
rng(data.INTERLEAVE_KEY, 'twister');
shuffle_map = randperm(data.num_encoded_bits);
extracted_encoded_bits = zeros(1, data.num_encoded_bits);
extracted_encoded_bits(shuffle_map) = extracted_interleaved_bits;

disp('--- Hamming (7,4) Decoding ---');
[decoded_bits, corrected_errors] = hamming74_decode(extracted_encoded_bits);
disp(['Corrected single-bit errors = ', num2str(corrected_errors)]);

decoded_bits = decoded_bits(1:num_watermark_bits);
extracted_watermark_bin = reshape(decoded_bits,[rows cols]);
extracted_watermark = uint8(extracted_watermark_bin) * 255;
imwrite(extracted_watermark, 'extracted_watermark_from_audio.png');
disp('Watermark extracted successfully!');

%% ============================================================
%% 8. QUALITY ASSESSMENT (ACCURACY)
%% ============================================================

orig_bits = watermark_binary(:);
ext_bits  = extracted_watermark_bin(:);
BER = sum(orig_bits ~= ext_bits) / length(orig_bits);
mean_orig = mean(orig_bits);
mean_ext  = mean(ext_bits);
num_nc = sum((orig_bits - mean_orig) .* (ext_bits - mean_ext));
den_nc = sqrt(sum((orig_bits - mean_orig).^2) * sum((ext_bits - mean_ext).^2));
if den_nc == 0, NC = 0; else, NC = num_nc / den_nc; end

disp('--- Accuracy Metrics ---');
disp(['Bit Error Rate (BER) : ', num2str(BER, '%.4f')]);
disp(['Normalized Corr (NC) : ', num2str(NC, '%.4f')]);

%% ============================================================
%% HAMMING FUNCTIONS (UNCHANGED)
%% ============================================================
function encoded = hamming74_encode(data)
    data = data(:)';
    num_groups = length(data)/4;
    encoded = zeros(1,num_groups*7);
    for k = 1:num_groups
        d1 = data(4*k-3); d2 = data(4*k-2); d3 = data(4*k-1); d4 = data(4*k);
        p1 = mod(d1+d2+d4,2); p2 = mod(d1+d3+d4,2); p4 = mod(d2+d3+d4,2);
        encoded(7*k-6:7*k) = [p1 p2 d1 p4 d2 d3 d4];
    end
end

function [data,corrected_errors] = hamming74_decode(encoded)
    encoded = encoded(:)';
    num_groups = length(encoded)/7;
    data = zeros(1,num_groups*4);
    corrected_errors = 0;
    for k = 1:num_groups
        block = encoded(7*k-6:7*k);
        s1 = mod(block(1)+block(3)+block(5)+block(7),2);
        s2 = mod(block(2)+block(3)+block(6)+block(7),2);
        s4 = mod(block(4)+block(5)+block(6)+block(7),2);
        syndrome = s1 + 2*s2 + 4*s4;
        if syndrome ~= 0 && syndrome <= 7
            block(syndrome) = 1-block(syndrome);
            corrected_errors = corrected_errors+1;
        end
        data(4*k-3:4*k) = [block(3) block(5) block(6) block(7)];
    end
end

%% ============================================================
%% 9. ABLATION STUDY HELPER DECODE FUNCTION 
%% ============================================================
function extracted_watermark_bin = full_decode(audio_int, data, use_sync, use_interleave, use_hamming, decode_key)
    audio_bits = double(bitget(audio_int, data.EMBED_BIT))';
    audio_length = length(audio_bits);
    
    found_frame_starts = [];
    if use_sync
        pattern_signal = 2*data.START_PATTERN - 1;
        correlation_values = zeros(1, length(audio_bits) - data.START_LEN + 1);
        for i = 1:length(correlation_values)
            segment = audio_bits(i : i + data.START_LEN - 1);
            segment_signal = 2*segment - 1;
            correlation_values(i) = sum(pattern_signal .* segment_signal) / data.START_LEN;
        end
        ADAPTIVE_THRESHOLD = max(0.35, max(correlation_values) - 0.35); 
        search_pos = 1;
        while search_pos <= length(correlation_values)
            if correlation_values(search_pos) >= ADAPTIVE_THRESHOLD
                found_frame_starts(end+1) = search_pos;
                search_pos = search_pos + data.FRAME_SIZE;
            else
                search_pos = search_pos + 1;
            end
        end
    else
        found_frame_starts = 1 : data.FRAME_SIZE : (audio_length - data.FRAME_SIZE);
    end
    
    extracted_interleaved_bits = zeros(1, data.num_encoded_bits);
    
    for f = 1:length(found_frame_starts)
        frame_start = found_frame_starts(f);
        if frame_start + data.FRAME_SIZE - 1 > audio_length, continue; end
        
        header_locs = frame_start + data.START_LEN : frame_start + data.START_LEN + data.HEADER_LEN - 1;
        header_extracted = audio_bits(header_locs);
        id1 = header_extracted(1:data.FRAME_ID_BITS);
        id2 = header_extracted(data.FRAME_ID_BITS+1:2*data.FRAME_ID_BITS);
        id3 = header_extracted(2*data.FRAME_ID_BITS+1:3*data.FRAME_ID_BITS);
        voted_id_bin = mode([id1; id2; id3], 1);
        extracted_frame_id = bin2dec(char(voted_id_bin + '0'));
        
        if extracted_frame_id < 1 || extracted_frame_id > data.num_frames
            continue; 
        end
        
        rng(decode_key + extracted_frame_id * 1000, 'twister');
        payload_locs = randperm(data.PAYLOAD_AREA) + data.START_LEN + data.HEADER_LEN;
        
        start_idx = (extracted_frame_id - 1) * data.PAYLOAD_BITS_PER_FRAME + 1;
        end_idx = min(start_idx + data.PAYLOAD_BITS_PER_FRAME - 1, data.num_encoded_bits);
        bits_in_this_frame = end_idx - start_idx + 1;
        
        frame_bits = zeros(1, bits_in_this_frame);
        for k = 1:bits_in_this_frame
            loc = frame_start + payload_locs(k) - 1;
            frame_bits(k) = audio_bits(loc);
        end
        extracted_interleaved_bits(start_idx : end_idx) = frame_bits;
    end
    
    if use_interleave
        rng(data.INTERLEAVE_KEY, 'twister');
        shuffle_map = randperm(data.num_encoded_bits);
        extracted_encoded_bits = zeros(1, data.num_encoded_bits);
        extracted_encoded_bits(shuffle_map) = extracted_interleaved_bits;
    else
        extracted_encoded_bits = extracted_interleaved_bits;
    end
    
    if use_hamming
        [decoded_bits, ~] = hamming74_decode(extracted_encoded_bits);
    else
        decoded_bits = zeros(1, (length(extracted_encoded_bits)/7)*4);
        for k = 1:length(extracted_encoded_bits)/7
             block = extracted_encoded_bits(7*k-6 : 7*k);
             decoded_bits(4*k-3 : 4*k) = [block(3) block(5) block(6) block(7)];
        end
    end
    
    decoded_bits = decoded_bits(1:data.num_watermark_bits);
    extracted_watermark_bin = reshape(decoded_bits, [data.rows, data.cols]);
end

%% ============================================================
%% 10. PLOTTING RESULTS
%% ============================================================

disp('--- Generating Plots ---');

% 1. Image Comparison Figure
figure('Color', 'white', 'Name', 'Watermark Image Comparison');
subplot(1, 2, 1);
imshow(watermark_binary);
title('Original Watermark');

subplot(1, 2, 2);
imshow(extracted_watermark);
title(sprintf('Extracted Watermark\nAccuracy: NC = %.4f | BER = %.4f', NC, BER));

% 2. Audio Processing Pipeline Figure
figure('Color', 'white', 'Name', 'Audio Signal Pipeline');

% Original Audio
subplot(3, 1, 1);
plot(double(cover_int) / 32767);
title('Original Audio Waveform');
xlabel('Samples');
ylabel('Amplitude');
ylim([-1 1]);

% Watermarked & Noisy Audio
subplot(3, 1, 2);
plot(double(noisy_int) / 32767);
title(['Watermarked Audio with AWGN (Bit Layer ', num2str(EMBED_BIT), ')']);
xlabel('Samples');
ylabel('Amplitude');
ylim([-1 1]);

% Difference (The Watermark + Noise itself)
subplot(3, 1, 3);
difference = double(noisy_int) - double(cover_int);
plot(difference);
title('Signal Difference (Watermark + Injected Noise)');
xlabel('Samples');
ylabel('Amplitude Error');

disp('======================================================');
disp(' SIMULATION AND PLOTTING COMPLETED');
disp('======================================================');

%% ============================================================
%% ABLATION STUDY: 4x2 ATTACK SIMULATION GRID
%% ============================================================

disp('Loading watermarked audio and metadata for Ablation Study...');
[marked_audio_int, fs] = audioread('marked_audio.wav', 'native');
marked_audio_int = marked_audio_int(:);
data = load('watermark_metadata.mat');

orig_bits = watermark_binary(:);

figure('Color', 'white', 'Name', 'Watermarking System Ablation Study', 'Position', [100, 100, 800, 1000]);

%% ------------------------------------------------------------
%% ATTACK 1: HARSH AWGN (Proves Hamming 7,4)
%% ------------------------------------------------------------
disp('Simulating Attack 1: Harsh AWGN (20 dB)...');
noisy_double = awgn(double(marked_audio_int), 20, 'measured');
attack1_audio = int16(noisy_double);

ext_bits_robust = full_decode(attack1_audio, data, true, true, true, data.key);
ber_robust = sum(orig_bits ~= ext_bits_robust(:)) / length(orig_bits);

ext_bits_naive = full_decode(attack1_audio, data, true, true, false, data.key);
ber_naive = sum(orig_bits ~= ext_bits_naive(:)) / length(orig_bits);

subplot(4, 2, 1); imshow(reshape(ext_bits_naive, [data.rows, data.cols]));
title(sprintf('AWGN (No Error Correction)\nBER = %.4f', ber_naive));
subplot(4, 2, 2); imshow(reshape(ext_bits_robust, [data.rows, data.cols]));
title(sprintf('AWGN (With Hamming 7,4)\nBER = %.4f', ber_robust));

%% ------------------------------------------------------------
%% ATTACK 2: BURST ERROR (Proves Interleaving)
%% ------------------------------------------------------------
disp('Simulating Attack 2: Localized Burst Error...');
attack2_audio = marked_audio_int;
% Obliterate 5000 samples (simulating an audio dropout or scratch)
attack2_audio(10000:15000) = int16(randi([-500, 500], 5001, 1)); 

ext_bits_robust = full_decode(attack2_audio, data, true, true, true, data.key);
ber_robust = sum(orig_bits ~= ext_bits_robust(:)) / length(orig_bits);

ext_bits_naive = full_decode(attack2_audio, data, true, false, true, data.key);
ber_naive = sum(orig_bits ~= ext_bits_naive(:)) / length(orig_bits);

subplot(4, 2, 3); imshow(reshape(ext_bits_naive, [data.rows, data.cols]));
title(sprintf('Burst Attack (No Interleaving)\nBER = %.4f', ber_naive));
subplot(4, 2, 4); imshow(reshape(ext_bits_robust, [data.rows, data.cols]));
title(sprintf('Burst Attack (With Interleaving)\nBER = %.4f', ber_robust));

%% ------------------------------------------------------------
%% ATTACK 3: CROPPING (Proves Adaptive Frame Sync + Frame ID)
%% ------------------------------------------------------------
disp('Simulating Attack 3: Audio Cropping (Severe desync)...');
% Delete first 5000 samples (destroying the first ~20 frames entirely)
attack3_audio = marked_audio_int(5001:end); 

ext_bits_robust = full_decode(attack3_audio, data, true, true, true, data.key);
ber_robust = sum(orig_bits ~= ext_bits_robust(:)) / length(orig_bits);

ext_bits_naive = full_decode(attack3_audio, data, false, true, true, data.key);
ber_naive = sum(orig_bits ~= ext_bits_naive(:)) / length(orig_bits);

subplot(4, 2, 5); imshow(reshape(ext_bits_naive, [data.rows, data.cols]));
title(sprintf('Severe Cropping (Fixed Sync)\nBER = %.4f', ber_naive));
subplot(4, 2, 6); imshow(reshape(ext_bits_robust, [data.rows, data.cols]));
title(sprintf('Severe Cropping (Adaptive Sync + TMR)\nBER = %.4f', ber_robust));

%% ------------------------------------------------------------
%% ATTACK 4: UNAUTHORIZED EXTRACTION (Proves PRNG Security)
%% ------------------------------------------------------------
disp('Simulating Attack 4: Wrong Extraction Key...');
attack4_audio = marked_audio_int;

ext_bits_robust = full_decode(attack4_audio, data, true, true, true, data.key);
ber_robust = sum(orig_bits ~= ext_bits_robust(:)) / length(orig_bits);

wrong_key = 99999;
ext_bits_naive = full_decode(attack4_audio, data, true, true, true, wrong_key);
ber_naive = sum(orig_bits ~= ext_bits_naive(:)) / length(orig_bits);

subplot(4, 2, 7); imshow(reshape(ext_bits_naive, [data.rows, data.cols]));
title(sprintf('Unauthorized (Wrong Key)\nBER = %.4f', ber_naive));
subplot(4, 2, 8); imshow(reshape(ext_bits_robust, [data.rows, data.cols]));
title(sprintf('Authorized (Correct Key)\nBER = %.4f', ber_robust));

disp('Ablation study completed.');
